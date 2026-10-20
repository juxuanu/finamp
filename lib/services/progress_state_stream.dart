import 'package:audio_service/audio_service.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import 'playback/playback_controller.dart';

class ProgressState {
  final MediaItem? mediaItem;
  final PlaybackState playbackState;
  final Duration position;

  ProgressState(this.mediaItem, this.playbackState, this.position);
}

/// Encapsulate all the different data we're interested in into a single
/// stream so we don't have to nest StreamBuilders.
Stream<ProgressState> get progressStateStream {
  final playback = GetIt.instance<PlaybackController>();
  return Rx.combineLatest3<MediaItem?, PlaybackState, Duration, ProgressState>(
    playback.mediaItem,
    playback.playbackState,
    AudioService.position.startWith(playback.playbackState.value.position),
    (mediaItem, playbackState, position) => ProgressState(mediaItem, playbackState, position),
  );
}

ProgressState? get progressState {
  final playback = GetIt.instance<PlaybackController>();
  return ProgressState(
    playback.mediaItem.value,
    playback.playbackState.value,
    playback.playbackState.value.position,
  );
}
