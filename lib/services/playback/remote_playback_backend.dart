import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/music_slices.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/playback/playback_backend.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

/// Another Jellyfin session of the current user, controlled remotely ("Play On").
///
/// Commands are sent to the server, which forwards them to the session. State
/// comes from the session feed the server pushes over the Play On websocket
/// (see [PlaybackController]) and is mirrored into this backend's streams:
/// track, queue, play state, position, repeat and shuffle mode.
class RemotePlaybackBackend implements PlaybackBackend {
  static final _logger = Logger("RemotePlaybackBackend");

  /// Jellyfin sends item ids as a query parameter, so play requests are limited to this many items.
  static const _maxPlayItems = 200;

  RemotePlaybackBackend({
    required SessionInfo session,
    required JellyfinApiHelper jellyfinApiHelper,
    required QueueService queueService,
  }) : _session = session,
       _jellyfinApiHelper = jellyfinApiHelper,
       _queueService = queueService;

  final JellyfinApiHelper _jellyfinApiHelper;
  final QueueService _queueService;

  SessionInfo _session;
  SessionInfo get session => _session;
  String get _sessionId => _session.id!;

  final _currentTrack = BehaviorSubject<FinampQueueItem?>.seeded(null);
  final _queue = BehaviorSubject<FinampQueueInfo?>.seeded(null);
  final _loopMode = BehaviorSubject<FinampLoopMode>.seeded(FinampLoopMode.none);
  final _playbackOrder = BehaviorSubject<FinampPlaybackOrder>.seeded(FinampPlaybackOrder.linear);
  final _playbackState = BehaviorSubject<PlaybackState>.seeded(PlaybackState());
  final _mediaItem = BehaviorSubject<MediaItem?>.seeded(null);

  // Mirroring bookkeeping
  BaseItemId? _mirroredItemId;
  String? _mirroredQueueKey;
  String? _pendingQueueKey;
  final Map<BaseItemId, MediaItem> _mediaItemCache = {};
  List<BaseItemDto> _remoteItems = [];
  List<FinampQueueItem> _remoteQueue = [];
  int _remoteQueueIndex = -1;
  bool _playing = false;
  Duration _position = Duration.zero;

  @override
  ValueStream<FinampQueueItem?> get currentTrack => _currentTrack;
  @override
  ValueStream<FinampQueueInfo?> get queue => _queue;
  @override
  ValueStream<FinampLoopMode> get loopMode => _loopMode;
  @override
  ValueStream<FinampPlaybackOrder> get playbackOrder => _playbackOrder;
  @override
  ValueStream<PlaybackState> get playbackState => _playbackState;
  @override
  ValueStream<MediaItem?> get mediaItem => _mediaItem;

  @override
  bool supports(PlaybackCapability capability) {
    final command = capability.jellyfinCommand;
    if (command == null) return false;
    return (_session.supportedCommands ?? _session.capabilities?.supportedCommands ?? const []).contains(command);
  }

  Future<void> dispose() async {
    await Future.wait([
      _currentTrack.close(),
      _queue.close(),
      _loopMode.close(),
      _playbackOrder.close(),
      _playbackState.close(),
      _mediaItem.close(),
    ]);
  }

  // Transport

  @override
  Future<void> play() => _sendPlaystateCommand("Unpause");
  @override
  Future<void> pause() => _sendPlaystateCommand("Pause");
  @override
  Future<void> togglePlayback() => _sendPlaystateCommand("PlayPause");
  @override
  Future<void> stop() => _sendPlaystateCommand("Stop");
  @override
  Future<void> skipToNext() => _sendPlaystateCommand("NextTrack");
  @override
  Future<void> skipToPrevious({bool forceSkip = false}) => _sendPlaystateCommand("PreviousTrack");
  @override
  Future<void> seek(Duration position) => _sendPlaystateCommand("Seek", seekPosition: position);
  @override
  Future<void> setVolume(double volume) => _sendGeneralCommand("SetVolume", {"Volume": "${(volume * 100).round()}"});

  Future<void> _sendPlaystateCommand(String command, {Duration? seekPosition}) async {
    await _jellyfinApiHelper.sendPlaystateCommand(sessionId: _sessionId, command: command, seekPosition: seekPosition);
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

  Future<void> _sendGeneralCommand(String name, Map<String, String> arguments) =>
      _jellyfinApiHelper.sendGeneralCommand(sessionId: _sessionId, name: name, arguments: arguments);

  // Queue

  @override
  Future<void> startPlayback({
    required List<BaseItemDto> items,
    required QueueItemSource source,
    QueueItemSource? customTrackSource,
    FinampPlaybackOrder? order,
    int? startingIndex,
    bool skipRadioCacheInvalidation = false,
  }) {
    // Jellyfin plays the items in the order given, so shuffle here if requested
    final shuffled = order == FinampPlaybackOrder.shuffled;
    return _play(shuffled ? ([...items]..shuffle()) : items, startIndex: shuffled ? 0 : startingIndex ?? 0);
  }

  @override
  Future<void> startSlicePlayback(PlayableSlice slice) async {
    final base = await slice.resolve(preShuffle: true);
    return _play(base.items, startIndex: base.startingIndex);
  }

  @override
  Future<void> addToQueue(PlayableSlice slice) async {
    final base = await slice.resolve(preShuffle: true);
    return _play(base.items, playCommand: "PlayLast");
  }

  @override
  Future<void> addNext(PlayableSlice slice) => addToNextUp(slice);

  @override
  Future<void> addToNextUp(PlayableSlice slice) async {
    final base = await slice.resolve(preShuffle: true);
    return _play(base.items, playCommand: "PlayNext");
  }

  /// Jellyfin has no command to jump within a session's queue, so this
  /// restarts the queue at [offset] from the current item. The remote session
  /// loses its queue identity (and shuffle order) as a consequence.
  @override
  Future<void> skipByOffset(int offset) async {
    final index = _remoteQueueIndex + offset;
    _logger.fine("Skipping remote queue by $offset to index $index of ${_remoteItems.length}");
    if (index < 0 || index >= _remoteItems.length) return;
    await _play(_remoteItems, startIndex: index);
  }

  // Jellyfin has no commands for editing a remote session's queue (see PlaybackCapability.editQueue)
  @override
  Future<void> removeAtOffset(int offset) async => _logger.warning("Removing from a remote queue is not supported");
  @override
  Future<void> reorderByOffset(int oldOffset, int newOffset) async =>
      _logger.warning("Reordering a remote queue is not supported");
  @override
  Future<void> clearNextUp() async => _logger.warning("Clearing a remote queue is not supported");

  /// Sends [items] to the session. [playCommand] is one of "PlayNow", "PlayNext" or "PlayLast".
  Future<void> _play(List<BaseItemDto> items, {String playCommand = "PlayNow", int startIndex = 0}) async {
    // Keep the starting item inside the window of items that can be sent
    final start = min(max(0, startIndex - _maxPlayItems ~/ 4), max(0, items.length - _maxPlayItems));
    final window = items.sublist(start, min(items.length, start + _maxPlayItems));
    await _jellyfinApiHelper.playOnSession(
      sessionId: _sessionId,
      itemIds: window.map((item) => item.id).toList(),
      playCommand: playCommand,
      startIndex: startIndex - start,
    );
  }

  // Modes

  @override
  Future<void> setLoopMode(FinampLoopMode mode) async {
    if (!supports(PlaybackCapability.setRepeatMode)) return;
    // Show the new mode until the session reports it
    _loopMode.add(mode);
    await _sendGeneralCommand("SetRepeatMode", {
      "RepeatMode": switch (mode) {
        FinampLoopMode.one => "RepeatOne",
        FinampLoopMode.all => "RepeatAll",
        FinampLoopMode.none => "RepeatNone",
      },
    });
  }

  @override
  Future<void> setPlaybackOrder(FinampPlaybackOrder order, {List<int>? shuffleOrder}) async {
    if (!supports(PlaybackCapability.setShuffle)) return;
    _playbackOrder.add(order);
    await _sendGeneralCommand("SetShuffleQueue", {
      "ShuffleMode": order == FinampPlaybackOrder.shuffled ? "Shuffle" : "Sorted",
    });
  }

  @override
  Future<void> toggleLoopMode() => setLoopMode(_loopMode.value.next);

  @override
  Future<void> togglePlaybackOrder() => setPlaybackOrder(_playbackOrder.value.toggled);

  // Mirroring

  /// Mirrors a session update pushed by the server.
  Future<void> updateSession(SessionInfo session) async {
    _session = session;
    if (session.nowPlayingItem == null && _mirroredItemId != null) {
      // Clients report nothing playing both between tracks and when stopped.
      // Like the local player at the end of playback, keep the last track on
      // screen and show it paused; the next track replaces it when it starts.
      _playing = false;
      _pushPlaybackState();
      return;
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
    id: item?.id ?? BaseItemId(_sessionId),
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
        // Not all servers send the full items
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
      _logger.fine("Mirrored remote queue of ${items.length} items, current index $index");

      final current = index >= 0 && index < queue.length ? queue[index] : null;
      _queue.add(
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
    _currentTrack.add(queueItem);
    _mediaItem.add(queueItem?.item);
  }

  void _mirrorModes(PlayerStateInfo? playState) {
    final repeatMode = playState?.repeatMode;
    if (repeatMode != null) {
      final loopMode = switch (repeatMode) {
        "RepeatOne" => FinampLoopMode.one,
        "RepeatAll" => FinampLoopMode.all,
        _ => FinampLoopMode.none,
      };
      if (_loopMode.value != loopMode) _loopMode.add(loopMode);
    }
    final playbackOrder = playState?.playbackOrder;
    if (playbackOrder != null) {
      final order = playbackOrder == "Shuffle" ? FinampPlaybackOrder.shuffled : FinampPlaybackOrder.linear;
      if (_playbackOrder.value != order) _playbackOrder.add(order);
    }
  }

  void _pushPlaybackState() {
    _playbackState.add(
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
