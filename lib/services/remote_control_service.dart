import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:collection/collection.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

/// Remote-controls another Jellyfin session of the current user ("Play On").
///
/// While a session is controlled, local playback is paused, playback commands
/// and play requests are forwarded to the remote session, and the remote
/// session's playback state is mirrored into the local player UI.
class RemoteControlService {
  static final _logger = Logger("RemoteControlService");
  static const _pollInterval = Duration(seconds: 2);

  /// The session currently being controlled, or null when controlling local playback.
  static final StateProvider<SessionInfo?> controlledSessionProvider = StateProvider((ref) => null);

  final _jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
  final _audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
  final _queueService = GetIt.instance<QueueService>();
  final _providerContainer = GetIt.instance<ProviderContainer>();

  SessionInfo? _session;
  Timer? _pollTimer;
  BaseItemId? _mirroredItemId;

  bool get isControlling => _session != null;
  SessionInfo? get session => _session;

  /// Starts controlling [session] instead of the local player.
  Future<void> control(SessionInfo session) async {
    _logger.info("Controlling session ${session.id} (${session.deviceName})");
    // Pause before switching so this is still handled by the local player
    await _audioHandler.pause(disableFade: true);
    _session = session;
    _providerContainer.read(controlledSessionProvider.notifier).state = session;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _poll());
    await _poll();
  }

  /// Stops controlling the remote session and restores the local player state in the UI.
  Future<void> release() async {
    if (_session == null) return;
    _logger.info("Stopped controlling session ${_session!.id}");
    _pollTimer?.cancel();
    _pollTimer = null;
    _session = null;
    _mirroredItemId = null;
    _providerContainer.read(controlledSessionProvider.notifier).state = null;
    final localTrack = _queueService.getCurrentTrack();
    _queueService.getCurrentTrackStream().add(localTrack);
    _audioHandler.mediaItem.add(localTrack?.item);
    await _audioHandler.refreshPlaybackStateAndMediaNotification();
  }

  /// Sends a playstate command (e.g. "PlayPause", "NextTrack", "Seek") to the controlled session.
  Future<void> sendPlaystateCommand(String command, {Duration? seekPosition}) async {
    await _jellyfinApiHelper.sendPlaystateCommand(
      sessionId: _session!.id!,
      command: command,
      seekPosition: seekPosition,
    );
    _pollSoon();
  }

  /// Plays [items] on the controlled session. [playCommand] is one of "PlayNow", "PlayNext" or "PlayLast".
  Future<void> play(List<BaseItemDto> items, {String playCommand = "PlayNow", int startIndex = 0}) async {
    await _jellyfinApiHelper.playOnSession(
      sessionId: _session!.id!,
      itemIds: items.map((item) => item.id).toList(),
      playCommand: playCommand,
      startIndex: startIndex,
    );
    _pollSoon();
  }

  /// Give the remote session a moment to apply a command before mirroring its state.
  void _pollSoon() => unawaited(Future.delayed(const Duration(milliseconds: 500), _poll));

  Future<void> _poll() async {
    final sessionId = _session?.id;
    if (sessionId == null) return;
    try {
      final sessions = await _jellyfinApiHelper.getControllableSessions();
      // Released while fetching
      if (_session?.id != sessionId) return;
      final session = sessions.firstWhereOrNull((session) => session.id == sessionId);
      if (session == null) {
        _logger.warning("Controlled session is gone, stopping remote control");
        await release();
        return;
      }
      _session = session;
      await _mirrorState(session);
    } catch (e) {
      _logger.warning("Failed to fetch controlled session state: $e");
    }
  }

  Future<void> _mirrorState(SessionInfo session) async {
    final item = session.nowPlayingItem;
    if (item?.id != _mirroredItemId) {
      _mirroredItemId = item?.id;
      MediaItem? mediaItem;
      FinampQueueItem? queueItem;
      if (item != null) {
        mediaItem = await _queueService.generateMediaItem(item);
        queueItem = FinampQueueItem(
          item: mediaItem,
          source: QueueItemSource(
            name: QueueItemSourceName(type: QueueItemSourceNameType.remoteClient),
            type: QueueItemSourceType.remoteClient,
            id: item.id,
            item: item,
          ),
        );
      }
      _queueService.getCurrentTrackStream().add(queueItem);
      _audioHandler.mediaItem.add(mediaItem);
    }
    final playState = session.playState;
    final playing = item != null && !(playState?.isPaused ?? true);
    _audioHandler.playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
        processingState: item == null ? AudioProcessingState.idle : AudioProcessingState.ready,
        playing: playing,
        updatePosition: Duration(microseconds: ((playState?.positionTicks ?? 0) / 10).round()),
        speed: 1.0,
      ),
    );
  }
}
