import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/music_slices.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/playback/playback_backend.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:rxdart/rxdart.dart';

/// This device's player: the just_audio based [MusicPlayerBackgroundTask] and
/// the [QueueService]. Supports every capability.
class LocalPlaybackBackend implements PlaybackBackend {
  LocalPlaybackBackend({required MusicPlayerBackgroundTask audioHandler, required QueueService queueService})
    : _audioHandler = audioHandler,
      _queueService = queueService;

  final MusicPlayerBackgroundTask _audioHandler;
  final QueueService _queueService;

  @override
  Future<void> play() => _audioHandler.play();
  @override
  Future<void> pause() => _audioHandler.pause();
  @override
  Future<void> togglePlayback() => _audioHandler.togglePlayback();
  @override
  Future<void> stop() => _audioHandler.stop();
  @override
  Future<void> skipToNext() => _audioHandler.skipToNext();
  @override
  Future<void> skipToPrevious({bool forceSkip = false}) => _audioHandler.skipToPrevious(forceSkip: forceSkip);
  @override
  Future<void> seek(Duration position) => _audioHandler.seek(position);
  @override
  Future<void> setVolume(double volume) async => _audioHandler.setVolume(volume);

  @override
  Future<void> startPlayback({
    required List<BaseItemDto> items,
    required QueueItemSource source,
    QueueItemSource? customTrackSource,
    FinampPlaybackOrder? order,
    int? startingIndex,
    bool skipRadioCacheInvalidation = false,
  }) => _queueService.startPlayback(
    items: items,
    source: source,
    customTrackSource: customTrackSource,
    order: order,
    startingIndex: startingIndex,
    skipRadioCacheInvalidation: skipRadioCacheInvalidation,
  );
  @override
  Future<void> startSlicePlayback(PlayableSlice slice) => _queueService.startSlicePlayback(slice);
  @override
  Future<void> addToQueue(PlayableSlice slice) => _queueService.addToQueue(slice);
  @override
  Future<void> addNext(PlayableSlice slice) => _queueService.addNext(slice);
  @override
  Future<void> addToNextUp(PlayableSlice slice) => _queueService.addToNextUp(slice);
  @override
  Future<void> skipByOffset(int offset) => _queueService.skipByOffset(offset);
  @override
  Future<void> removeAtOffset(int offset) => _queueService.removeAtOffset(offset);
  @override
  Future<void> reorderByOffset(int oldOffset, int newOffset) => _queueService.reorderByOffset(oldOffset, newOffset);
  @override
  Future<void> clearNextUp() => _queueService.clearNextUp();

  @override
  Future<void> setLoopMode(FinampLoopMode mode) async => _queueService.loopMode = mode;
  @override
  Future<void> setPlaybackOrder(FinampPlaybackOrder order, {List<int>? shuffleOrder}) =>
      _queueService.setPlaybackOrder(order, shuffleOrder: shuffleOrder);
  @override
  Future<void> toggleLoopMode() async => _queueService.toggleLoopMode();
  @override
  Future<void> togglePlaybackOrder() => _queueService.togglePlaybackOrder();

  @override
  bool supports(PlaybackCapability capability) => true;

  @override
  ValueStream<FinampQueueItem?> get currentTrack => _queueService.getCurrentTrackStream();
  @override
  ValueStream<FinampQueueInfo?> get queue => _queueService.getQueueStream();
  @override
  ValueStream<FinampLoopMode> get loopMode => _queueService.getLoopModeStream();
  @override
  ValueStream<FinampPlaybackOrder> get playbackOrder => _queueService.getPlaybackOrderStream();
  @override
  ValueStream<PlaybackState> get playbackState => _audioHandler.playbackState;
  @override
  ValueStream<MediaItem?> get mediaItem => _audioHandler.mediaItem;
}
