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
  Future<void> play() => _audioHandler.playLocal();
  @override
  Future<void> pause() => _audioHandler.pauseLocal();
  @override
  Future<void> togglePlayback() => _audioHandler.togglePlaybackLocal();
  @override
  Future<void> stop() => _audioHandler.stopLocal();
  @override
  Future<void> skipToNext() => _audioHandler.skipToNextLocal();
  @override
  Future<void> skipToPrevious({bool forceSkip = false}) => _audioHandler.skipToPreviousLocal(forceSkip: forceSkip);
  @override
  Future<void> seek(Duration position) => _audioHandler.seekLocal(position);
  @override
  Future<void> setVolume(double volume) async => _audioHandler.setVolumeLocal(volume);

  @override
  Future<void> startPlayback({
    required List<BaseItemDto> items,
    required QueueItemSource source,
    QueueItemSource? customTrackSource,
    FinampPlaybackOrder? order,
    int? startingIndex,
    bool skipRadioCacheInvalidation = false,
  }) => _queueService.startPlaybackLocal(
    items: items,
    source: source,
    customTrackSource: customTrackSource,
    order: order,
    startingIndex: startingIndex,
    skipRadioCacheInvalidation: skipRadioCacheInvalidation,
  );
  @override
  Future<void> startSlicePlayback(PlayableSlice slice) => _queueService.startSlicePlaybackLocal(slice);
  @override
  Future<void> addToQueue(PlayableSlice slice) => _queueService.addToQueueLocal(slice);
  @override
  Future<void> addNext(PlayableSlice slice) => _queueService.addNextLocal(slice);
  @override
  Future<void> addToNextUp(PlayableSlice slice) => _queueService.addToNextUpLocal(slice);
  @override
  Future<void> skipByOffset(int offset) => _queueService.skipByOffsetLocal(offset);
  @override
  Future<void> removeAtOffset(int offset) => _queueService.removeAtOffsetLocal(offset);
  @override
  Future<void> reorderByOffset(int oldOffset, int newOffset) =>
      _queueService.reorderByOffsetLocal(oldOffset, newOffset);
  @override
  Future<void> clearNextUp() => _queueService.clearNextUpLocal();

  @override
  Future<void> setLoopMode(FinampLoopMode mode) async => _queueService.setLoopModeLocal(mode);
  @override
  Future<void> setPlaybackOrder(FinampPlaybackOrder order, {List<int>? shuffleOrder}) =>
      _queueService.setPlaybackOrderLocal(order, shuffleOrder: shuffleOrder);
  @override
  Future<void> toggleLoopMode() async => _queueService.toggleLoopModeLocal();
  @override
  Future<void> togglePlaybackOrder() => _queueService.togglePlaybackOrderLocal();

  @override
  bool supports(PlaybackCapability capability) => true;

  @override
  ValueStream<FinampQueueItem?> get currentTrack => _queueService.localCurrentTrack;
  @override
  ValueStream<FinampQueueInfo?> get queue => _queueService.localQueue;
  @override
  ValueStream<FinampLoopMode> get loopMode => _queueService.localLoopMode;
  @override
  ValueStream<FinampPlaybackOrder> get playbackOrder => _queueService.localPlaybackOrder;
  @override
  ValueStream<PlaybackState> get playbackState => _audioHandler.localPlaybackState;
  @override
  ValueStream<MediaItem?> get mediaItem => _audioHandler.localMediaItem;
}
