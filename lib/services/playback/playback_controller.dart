import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:collection/collection.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/music_slices.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/playback/local_playback_backend.dart';
import 'package:finamp/services/playback/playback_backend.dart';
import 'package:finamp/services/playback/remote_playback_backend.dart';
import 'package:finamp/services/playon_service.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

/// The playback the user controls: this device's player, or a remote Jellyfin
/// session while "Play On" is in use.
///
/// It is itself a [PlaybackBackend] that forwards to the active one, and its
/// streams follow whichever backend is active. UI, OS media session and
/// services only talk to this controller; the local player keeps its own state
/// while a remote session is controlled and reappears unchanged on release.
class PlaybackController implements PlaybackBackend {
  static final _logger = Logger("PlaybackController");

  /// The remote session being controlled, or null while this device's player is active.
  static final StateProvider<SessionInfo?> controlledSessionProvider = StateProvider((ref) => null);

  /// The active backend, for widgets (rebuilds whenever it switches).
  static final Provider<PlaybackBackend> backendProvider = Provider((ref) {
    ref.watch(controlledSessionProvider);
    return GetIt.instance<PlaybackController>().backend;
  });

  static final _queueStreamProvider = StreamProvider((ref) => GetIt.instance<PlaybackController>().queue);

  /// The queue of the active backend, for widgets.
  static final Provider<FinampQueueInfo?> queueProvider = Provider((ref) => ref.watch(_queueStreamProvider).value);

  PlaybackController({
    required this.local,
    required QueueService queueService,
    required JellyfinApiHelper jellyfinApiHelper,
    required PlayOnService playOnService,
    required ProviderContainer providers,
  }) : _queueService = queueService,
       _jellyfinApiHelper = jellyfinApiHelper,
       _playOnService = playOnService,
       _providers = providers {
    _attach(local);
  }

  /// This device's player.
  final LocalPlaybackBackend local;
  final QueueService _queueService;
  final JellyfinApiHelper _jellyfinApiHelper;
  final PlayOnService _playOnService;
  final ProviderContainer _providers;

  RemotePlaybackBackend? _remote;

  /// The backend commands go to.
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

  // Commands, forwarded to the active backend

  @override
  Future<void> play() => backend.play();
  @override
  Future<void> pause() => backend.pause();
  @override
  Future<void> togglePlayback() => backend.togglePlayback();
  @override
  Future<void> stop() => backend.stop();
  @override
  Future<void> skipToNext() => backend.skipToNext();
  @override
  Future<void> skipToPrevious({bool forceSkip = false}) => backend.skipToPrevious(forceSkip: forceSkip);
  @override
  Future<void> seek(Duration position) => backend.seek(position);
  @override
  Future<void> setVolume(double volume) => backend.setVolume(volume);

  @override
  Future<void> startPlayback({
    required List<BaseItemDto> items,
    required QueueItemSource source,
    QueueItemSource? customTrackSource,
    FinampPlaybackOrder? order,
    int? startingIndex,
    bool skipRadioCacheInvalidation = false,
  }) => backend.startPlayback(
    items: items,
    source: source,
    customTrackSource: customTrackSource,
    order: order,
    startingIndex: startingIndex,
    skipRadioCacheInvalidation: skipRadioCacheInvalidation,
  );
  @override
  Future<void> startSlicePlayback(PlayableSlice slice) => backend.startSlicePlayback(slice);
  @override
  Future<void> addToQueue(PlayableSlice slice) => backend.addToQueue(slice);
  @override
  Future<void> addNext(PlayableSlice slice) => backend.addNext(slice);
  @override
  Future<void> addToNextUp(PlayableSlice slice) => backend.addToNextUp(slice);
  @override
  Future<void> skipByOffset(int offset) => backend.skipByOffset(offset);
  @override
  Future<void> removeAtOffset(int offset) => backend.removeAtOffset(offset);
  @override
  Future<void> reorderByOffset(int oldOffset, int newOffset) => backend.reorderByOffset(oldOffset, newOffset);
  @override
  Future<void> clearNextUp() => backend.clearNextUp();

  @override
  Future<void> setLoopMode(FinampLoopMode mode) => backend.setLoopMode(mode);
  @override
  Future<void> setPlaybackOrder(FinampPlaybackOrder order, {List<int>? shuffleOrder}) =>
      backend.setPlaybackOrder(order, shuffleOrder: shuffleOrder);
  @override
  Future<void> toggleLoopMode() => backend.toggleLoopMode();
  @override
  Future<void> togglePlaybackOrder() => backend.togglePlaybackOrder();

  @override
  bool supports(PlaybackCapability capability) => backend.supports(capability);

  // Switching

  /// Follows [newBackend]'s streams. Its current values are emitted right away.
  void _attach(PlaybackBackend newBackend) {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions = [
      _follow(newBackend.currentTrack, _currentTrack),
      _follow(newBackend.queue, _queue),
      _follow(newBackend.loopMode, _loopMode),
      _follow(newBackend.playbackOrder, _playbackOrder),
      _follow(newBackend.playbackState, _playbackState),
      _follow(newBackend.mediaItem, _mediaItem),
    ];
  }

  /// Copies [source]'s current value into [target] right away, then forwards its events.
  StreamSubscription<void> _follow<T>(ValueStream<T> source, BehaviorSubject<T> target) {
    if (!source.hasValue) return source.listen(target.add);
    target.add(source.value);
    // Listening replays the current value again, asynchronously
    return source.skip(1).listen(target.add);
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
