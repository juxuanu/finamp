import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/music_slices.dart';
import 'package:rxdart/rxdart.dart';

/// Optional abilities of a [PlaybackBackend]. The local player supports all of
/// them; a remote session only what it advertises (see [jellyfinCommand]).
enum PlaybackCapability {
  setVolume("SetVolume"),
  setRepeatMode("SetRepeatMode"),
  setShuffle("SetShuffleQueue"),

  /// Removing and reordering queue items. Jellyfin has no remote command for this.
  editQueue(null);

  const PlaybackCapability(this.jellyfinCommand);

  /// The Jellyfin GeneralCommandType a remote session must list in its supported commands.
  final String? jellyfinCommand;
}

/// Something that plays music and exposes its state: either this device's
/// player or another Jellyfin session controlled remotely ("Play On").
///
/// UI and services only talk to the active backend through
/// [PlaybackController], so the user controls the same way whatever plays.
abstract interface class PlaybackBackend {
  // Transport
  Future<void> play();
  Future<void> pause();
  Future<void> togglePlayback();
  Future<void> stop();
  Future<void> skipToNext();
  Future<void> skipToPrevious({bool forceSkip = false});
  Future<void> seek(Duration position);

  /// Sets the volume, 0.0 to 1.0.
  Future<void> setVolume(double volume);

  // Queue
  Future<void> startPlayback({
    required List<BaseItemDto> items,
    required QueueItemSource source,
    QueueItemSource? customTrackSource,
    FinampPlaybackOrder? order,
    int? startingIndex,
    bool skipRadioCacheInvalidation = false,
  });
  Future<void> startSlicePlayback(PlayableSlice slice);
  Future<void> addToQueue(PlayableSlice slice);
  Future<void> addNext(PlayableSlice slice);
  Future<void> addToNextUp(PlayableSlice slice);

  /// Skips to the queue item [offset] positions away from the current one.
  Future<void> skipByOffset(int offset);
  Future<void> removeAtOffset(int offset);
  Future<void> reorderByOffset(int oldOffset, int newOffset);
  Future<void> clearNextUp();

  // Modes
  Future<void> setLoopMode(FinampLoopMode mode);
  Future<void> setPlaybackOrder(FinampPlaybackOrder order, {List<int>? shuffleOrder});

  bool supports(PlaybackCapability capability);

  // State
  ValueStream<FinampQueueItem?> get currentTrack;
  ValueStream<FinampQueueInfo?> get queue;
  ValueStream<FinampLoopMode> get loopMode;
  ValueStream<FinampPlaybackOrder> get playbackOrder;
  ValueStream<PlaybackState> get playbackState;
  ValueStream<MediaItem?> get mediaItem;
}
