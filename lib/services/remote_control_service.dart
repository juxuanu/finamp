import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:collection/collection.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/playon_service.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

/// Remote-controls another Jellyfin session of the current user ("Play On").
///
/// While a session is controlled, local playback is paused and all playback
/// commands, play requests, queue skips, volume, repeat and shuffle changes are
/// forwarded to the remote session. The remote session's state (track, queue,
/// play state, position, repeat and shuffle mode) is pushed by the server over
/// the Play On websocket and mirrored into the local player streams, so the
/// whole player UI reflects the remote session.
class RemoteControlService {
  static final _logger = Logger("RemoteControlService");

  /// Jellyfin sends item ids as a query parameter, so play requests are limited to this many items.
  static const _maxPlayItems = 200;

  /// How long a session has to report nothing playing before it's mirrored as stopped.
  /// The server pushes session updates every 1.5 seconds.
  static const _stopGracePeriod = Duration(seconds: 4);

  /// The session currently being controlled, or null when controlling local playback.
  static final StateProvider<SessionInfo?> controlledSessionProvider = StateProvider((ref) => null);

  final _jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
  final _audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
  final _queueService = GetIt.instance<QueueService>();
  final _playOnService = GetIt.instance<PlayOnService>();
  final _providerContainer = GetIt.instance<ProviderContainer>();

  SessionInfo? _session;

  // Mirrored remote state
  BaseItemId? _mirroredItemId;
  String? _mirroredQueueKey;
  String? _pendingQueueKey;
  DateTime? _nothingPlayingSince;
  final Map<BaseItemId, MediaItem> _mediaItemCache = {};
  List<BaseItemDto> _remoteItems = [];
  List<FinampQueueItem> _remoteQueue = [];
  int _remoteQueueIndex = -1;
  bool _playing = false;
  Duration _position = Duration.zero;

  bool get isControlling => _session != null;
  SessionInfo? get session => _session;

  /// Starts controlling [session] instead of the local player.
  /// Requires the Play On websocket to be connected, as the session state is pushed through it.
  Future<void> control(SessionInfo session) async {
    if (!_playOnService.isConnected) {
      _logger.warning("Can't control session ${session.id}, websocket is not connected");
      return;
    }
    _logger.info("Controlling session ${session.id} (${session.deviceName})");
    // Pause before switching so this is still handled by the local player
    await _audioHandler.pause(disableFade: true);
    _session = session;
    _providerContainer.read(controlledSessionProvider.notifier).state = session;
    _subscribeToSessionFeed();
    await _applySession(session);
  }

  /// Stops controlling the remote session and restores the local player state in the UI.
  Future<void> release() async {
    if (_session == null) return;
    _logger.info("Stopped controlling session ${_session!.id}");
    _playOnService.sendMessage('{"MessageType":"SessionsStop"}');
    _session = null;
    _mirroredItemId = null;
    _mirroredQueueKey = null;
    _pendingQueueKey = null;
    _nothingPlayingSince = null;
    _mediaItemCache.clear();
    _remoteItems = [];
    _remoteQueue = [];
    _remoteQueueIndex = -1;
    _providerContainer.read(controlledSessionProvider.notifier).state = null;
    // Restore the local player's state in the UI
    final localTrack = _queueService.getCurrentTrack();
    _queueService.getCurrentTrackStream().add(localTrack);
    _audioHandler.mediaItem.add(localTrack?.item);
    _queueService.getLoopModeStream().add(_queueService.loopMode);
    _queueService.getPlaybackOrderStream().add(_queueService.playbackOrder);
    _queueService.refreshQueueStream();
    await _audioHandler.refreshPlaybackStateAndMediaNotification();
  }

  /// Called by the [PlayOnService] whenever the websocket (re)connects.
  void onSocketConnected() {
    if (isControlling) _subscribeToSessionFeed();
  }

  /// Asks the server to push the session list over the websocket (initial delay 0ms, every 1500ms).
  void _subscribeToSessionFeed() => _playOnService.sendMessage('{"MessageType":"SessionsStart","Data":"0,1500"}');

  /// Called by the [PlayOnService] with the session list pushed by the server.
  Future<void> onSessionsUpdate(List<dynamic> sessions) async {
    final sessionId = _session?.id;
    if (sessionId == null) return;
    final sessionJson = sessions.firstWhereOrNull((session) => (session as Map)['Id'] == sessionId);
    if (sessionJson == null) {
      _logger.warning("Controlled session is gone, stopping remote control");
      await release();
      return;
    }
    final session = SessionInfo.fromJson(sessionJson as Map<String, dynamic>);
    _session = session;
    _providerContainer.read(controlledSessionProvider.notifier).state = session;
    await _applySession(session);
  }

  // Commands

  /// Sends a playstate command (e.g. "PlayPause", "NextTrack", "Seek") to the controlled session.
  Future<void> sendPlaystateCommand(String command, {Duration? seekPosition}) async {
    await _jellyfinApiHelper.sendPlaystateCommand(
      sessionId: _session!.id!,
      command: command,
      seekPosition: seekPosition,
    );
    // Update the mirrored state optimistically until the server pushes the result
    switch (command) {
      case "Pause" || "Stop":
        _playing = false;
      case "Unpause":
        _playing = true;
      case "PlayPause":
        _playing = !_playing;
      case "Seek":
        _position = seekPosition ?? _position;
      default:
        return;
    }
    _pushPlaybackState();
  }

  /// Plays [items] on the controlled session. [playCommand] is one of "PlayNow", "PlayNext" or "PlayLast".
  Future<void> play(List<BaseItemDto> items, {String playCommand = "PlayNow", int startIndex = 0}) async {
    // Keep the starting item inside the window of items that can be sent
    final start = min(max(0, startIndex - _maxPlayItems ~/ 4), max(0, items.length - _maxPlayItems));
    final window = items.sublist(start, min(items.length, start + _maxPlayItems));
    await _jellyfinApiHelper.playOnSession(
      sessionId: _session!.id!,
      itemIds: window.map((item) => item.id).toList(),
      playCommand: playCommand,
      startIndex: startIndex - start,
    );
  }

  /// Skips to the queue item [offset] positions away from the current one.
  Future<void> skipByOffset(int offset) async {
    final index = _remoteQueueIndex + offset;
    if (index < 0 || index >= _remoteItems.length) return;
    await play(_remoteItems, startIndex: index);
  }

  Future<void> setVolume(double volume) => _sendGeneralCommand("SetVolume", {"Volume": "${(volume * 100).round()}"});

  Future<void> setLoopMode(FinampLoopMode mode) => _sendGeneralCommand("SetRepeatMode", {
    "RepeatMode": switch (mode) {
      FinampLoopMode.one => "RepeatOne",
      FinampLoopMode.all => "RepeatAll",
      FinampLoopMode.none => "RepeatNone",
    },
  });

  Future<void> setShuffle(bool shuffle) =>
      _sendGeneralCommand("SetShuffleQueue", {"ShuffleMode": shuffle ? "Shuffle" : "Sorted"});

  Future<void> _sendGeneralCommand(String name, Map<String, String> arguments) =>
      _jellyfinApiHelper.sendGeneralCommand(sessionId: _session!.id!, name: name, arguments: arguments);

  // Mirroring

  Future<void> _applySession(SessionInfo session) async {
    // Between tracks, clients briefly report nothing playing. Keep showing the
    // last track for a moment so the player doesn't flicker, only a lasting
    // stop is mirrored.
    if (session.nowPlayingItem == null && _mirroredItemId != null) {
      _nothingPlayingSince ??= DateTime.now();
      if (DateTime.now().difference(_nothingPlayingSince!) < _stopGracePeriod) return;
    } else {
      _nothingPlayingSince = null;
    }
    await _mirrorQueue(session);
    await _mirrorTrack(session);
    _mirrorModes(session.playState);
    final playState = session.playState;
    _playing = session.nowPlayingItem != null && !(playState?.isPaused ?? true);
    _position = Duration(microseconds: ((playState?.positionTicks ?? 0) / 10).round());
    _pushPlaybackState();
  }

  Future<MediaItem> _mediaItemFor(BaseItemDto item) async =>
      _mediaItemCache[item.id] ??= await _queueService.generateMediaItem(item);

  QueueItemSource _remoteSource(BaseItemDto? item) => QueueItemSource(
    name: QueueItemSourceName(type: QueueItemSourceNameType.remoteClient),
    type: QueueItemSourceType.remoteClient,
    id: item?.id ?? BaseItemId(_session?.id ?? ""),
    item: item,
  );

  Future<void> _mirrorQueue(SessionInfo session) async {
    final ids = session.nowPlayingQueue?.map((queueItem) => queueItem.id).toList() ?? [];
    final nowPlaying = session.nowPlayingItem;
    final key = "${session.playlistItemId}|${nowPlaying?.id}|${ids.join(",")}";
    if (key == _mirroredQueueKey) return;
    _pendingQueueKey = key;

    try {
      var items = session.nowPlayingQueueFullItems ?? [];
      if (items.length != ids.length && ids.isNotEmpty) {
        // Servers before 10.9 don't send the full items
        final fetched = await _jellyfinApiHelper.getItems(itemIds: ids.map(BaseItemId.new).toList()) ?? [];
        final byId = {for (final item in fetched) item.id: item};
        items = ids.map((id) => byId[BaseItemId(id)]).nonNulls.toList();
      }
      var index = -1;
      if (session.playlistItemId != null) {
        index =
            session.nowPlayingQueue?.indexWhere((queueItem) => queueItem.playlistItemId == session.playlistItemId) ??
            -1;
      }
      if (index < 0 && nowPlaying != null) {
        index = items.indexWhere((item) => item.id == nowPlaying.id);
      }
      if (index < 0 && nowPlaying != null) {
        // The client reports no queue, or one without the current track, so show at least the current track
        items = [nowPlaying, ...items];
        index = 0;
      }
      final queue = <FinampQueueItem>[];
      for (final (i, item) in items.indexed) {
        queue.add(
          FinampQueueItem(
            item: await _mediaItemFor(item),
            source: _remoteSource(item),
            type: i < index
                ? QueueItemQueueType.previousTracks
                : i == index
                ? QueueItemQueueType.currentTrack
                : QueueItemQueueType.queue,
          ),
        );
      }
      // The session may have changed while generating the media items
      if (_pendingQueueKey != key) return;
      _mirroredQueueKey = key;
      _remoteItems = items;
      _remoteQueue = queue;
      _remoteQueueIndex = index;

      final current = index >= 0 && index < queue.length ? queue[index] : null;
      _queueService.getQueueStream().add(
        FinampQueueInfo(
          id: session.id ?? "",
          previousTracks: current == null ? [] : queue.sublist(0, index),
          currentTrack: current,
          nextUp: [],
          queue: current == null ? queue : queue.sublist(index + 1),
          source: _remoteSource(nowPlaying),
          saveState: SavedQueueState.saving,
          sourceLibrary: null,
        ),
      );
    } catch (e) {
      // Not caching the key, so the next session update retries
      _logger.warning("Failed to mirror the remote queue: $e");
    }
  }

  Future<void> _mirrorTrack(SessionInfo session) async {
    final item = session.nowPlayingItem;
    if (item?.id == _mirroredItemId) return;
    FinampQueueItem? queueItem;
    try {
      if (item != null) {
        final current = _remoteQueueIndex >= 0 && _remoteQueueIndex < _remoteQueue.length
            ? _remoteQueue[_remoteQueueIndex]
            : null;
        queueItem = current?.baseItemId == item.id
            ? current
            : FinampQueueItem(item: await _mediaItemFor(item), source: _remoteSource(item));
      }
    } catch (e) {
      // Not caching the id, so the next session update retries
      _logger.warning("Failed to mirror the remote track: $e");
      return;
    }
    _mirroredItemId = item?.id;
    _queueService.getCurrentTrackStream().add(queueItem);
    _audioHandler.mediaItem.add(queueItem?.item);
  }

  void _mirrorModes(PlayerStateInfo? playState) {
    final repeatMode = playState?.repeatMode;
    if (repeatMode != null) {
      final loopMode = switch (repeatMode) {
        "RepeatOne" => FinampLoopMode.one,
        "RepeatAll" => FinampLoopMode.all,
        _ => FinampLoopMode.none,
      };
      if (_queueService.getLoopModeStream().valueOrNull != loopMode) {
        _queueService.getLoopModeStream().add(loopMode);
      }
    }
    final playbackOrder = playState?.playbackOrder;
    if (playbackOrder != null) {
      final order = playbackOrder == "Shuffle" ? FinampPlaybackOrder.shuffled : FinampPlaybackOrder.linear;
      if (_queueService.getPlaybackOrderStream().valueOrNull != order) {
        _queueService.getPlaybackOrderStream().add(order);
      }
    }
  }

  /// Re-pushes the mirrored playback state, e.g. to refresh the media notification.
  Future<void> refreshPlaybackState() async => _pushPlaybackState();

  void _pushPlaybackState() {
    _audioHandler.playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          _playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
        processingState: _mirroredItemId == null ? AudioProcessingState.idle : AudioProcessingState.ready,
        playing: _playing,
        updatePosition: _position,
        speed: 1.0,
      ),
    );
  }
}
