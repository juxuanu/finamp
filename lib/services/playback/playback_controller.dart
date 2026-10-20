import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:collection/collection.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/playback/local_playback_backend.dart';
import 'package:finamp/services/playback/playback_backend.dart';
import 'package:finamp/services/playback/remote_playback_backend.dart';
import 'package:finamp/services/playon_service.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

/// Holds the active [PlaybackBackend]: this device's player, or a remote
/// Jellyfin session while "Play On" is in use.
///
/// Everything that controls playback goes through [backend], and everything
/// that shows playback state reads this controller's streams, which follow
/// whichever backend is active. Switching backends therefore never requires
/// touching the UI or the services: the local player keeps its own state while
/// a remote session is controlled, and it reappears unchanged on release.
class PlaybackController {
  static final _logger = Logger("PlaybackController");

  /// The remote session being controlled, or null while this device's player is active.
  static final StateProvider<SessionInfo?> controlledSessionProvider = StateProvider((ref) => null);

  /// The active backend, for widgets (rebuilds whenever it switches).
  static final Provider<PlaybackBackend> backendProvider = Provider((ref) {
    ref.watch(controlledSessionProvider);
    return GetIt.instance<PlaybackController>().backend;
  });

  PlaybackController({
    required this.local,
    required MusicPlayerBackgroundTask audioHandler,
    required QueueService queueService,
    required JellyfinApiHelper jellyfinApiHelper,
    required PlayOnService playOnService,
    required ProviderContainer providers,
  }) : _audioHandler = audioHandler,
       _queueService = queueService,
       _jellyfinApiHelper = jellyfinApiHelper,
       _playOnService = playOnService,
       _providers = providers {
    _attach(local);
  }

  /// This device's player.
  final LocalPlaybackBackend local;
  final MusicPlayerBackgroundTask _audioHandler;
  final QueueService _queueService;
  final JellyfinApiHelper _jellyfinApiHelper;
  final PlayOnService _playOnService;
  final ProviderContainer _providers;

  RemotePlaybackBackend? _remote;

  /// The backend playback commands go to.
  PlaybackBackend get backend => _remote ?? local;
  bool get isRemote => _remote != null;
  SessionInfo? get controlledSession => _remote?.session;

  // State of the active backend
  final _currentTrack = BehaviorSubject<FinampQueueItem?>();
  final _queue = BehaviorSubject<FinampQueueInfo?>();
  final _loopMode = BehaviorSubject<FinampLoopMode>();
  final _playbackOrder = BehaviorSubject<FinampPlaybackOrder>();
  final _playbackState = BehaviorSubject<PlaybackState>();
  final _mediaItem = BehaviorSubject<MediaItem?>();
  List<StreamSubscription<void>> _subscriptions = [];

  ValueStream<FinampQueueItem?> get currentTrack => _currentTrack;
  ValueStream<FinampQueueInfo?> get queue => _queue;
  ValueStream<FinampLoopMode> get loopMode => _loopMode;
  ValueStream<FinampPlaybackOrder> get playbackOrder => _playbackOrder;
  ValueStream<PlaybackState> get playbackState => _playbackState;
  ValueStream<MediaItem?> get mediaItem => _mediaItem;

  /// Follows [newBackend]'s streams. Its current values are emitted right away.
  void _attach(PlaybackBackend newBackend) {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions = [
      newBackend.currentTrack.listen(_currentTrack.add),
      newBackend.queue.listen(_queue.add),
      newBackend.loopMode.listen(_loopMode.add),
      newBackend.playbackOrder.listen(_playbackOrder.add),
      // The audio handler's own subjects drive the OS media session (notification, lock screen, car)
      newBackend.playbackState.listen((state) {
        _playbackState.add(state);
        _audioHandler.playbackState.add(state);
      }),
      newBackend.mediaItem.listen((item) {
        _mediaItem.add(item);
        _audioHandler.mediaItem.add(item);
      }),
    ];
  }

  /// Starts controlling [session] instead of this device's player.
  /// Requires the Play On websocket, as the session state is pushed through it.
  Future<void> control(SessionInfo session) async {
    if (!_playOnService.isConnected) {
      _logger.warning("Can't control session ${session.id}, websocket is not connected");
      return;
    }
    _logger.info("Controlling session ${session.id} (${session.deviceName})");
    await local.pause();
    final previous = _remote;
    final remote = RemotePlaybackBackend(
      session: session,
      jellyfinApiHelper: _jellyfinApiHelper,
      queueService: _queueService,
    );
    _remote = remote;
    _attach(remote);
    _providers.read(controlledSessionProvider.notifier).state = session;
    unawaited(previous?.dispose());
    _subscribeToSessionFeed();
    await remote.updateSession(session);
  }

  /// Stops controlling the remote session. This device's player, with its own
  /// unchanged state, becomes active again.
  Future<void> release() async {
    final remote = _remote;
    if (remote == null) return;
    _logger.info("Stopped controlling session ${remote.session.id}");
    _playOnService.sendMessage('{"MessageType":"SessionsStop"}');
    _remote = null;
    _attach(local);
    _providers.read(controlledSessionProvider.notifier).state = null;
    await remote.dispose();
  }

  /// Called by the [PlayOnService] whenever the websocket (re)connects.
  void onSocketConnected() {
    if (isRemote) _subscribeToSessionFeed();
  }

  /// Asks the server to push the session list over the websocket (initial delay 0ms, every 1500ms).
  void _subscribeToSessionFeed() => _playOnService.sendMessage('{"MessageType":"SessionsStart","Data":"0,1500"}');

  /// Called by the [PlayOnService] with the session list pushed by the server.
  Future<void> onSessionsUpdate(List<dynamic> sessions) async {
    final remote = _remote;
    if (remote == null) return;
    final sessionJson = sessions.firstWhereOrNull((session) => (session as Map)['Id'] == remote.session.id);
    if (sessionJson == null) {
      _logger.warning("Controlled session is gone, stopping remote control");
      await release();
      return;
    }
    final session = SessionInfo.fromJson(sessionJson as Map<String, dynamic>);
    _providers.read(controlledSessionProvider.notifier).state = session;
    await remote.updateSession(session);
  }
}
