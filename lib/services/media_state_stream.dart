import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import 'music_player_background_task.dart';
import 'playback/playback_controller.dart';

class MediaState {
  final MediaItem? mediaItem;
  final PlaybackState playbackState;
  final FadeDirection fadeDirection;

  MediaState(this.mediaItem, this.playbackState, this.fadeDirection);
}

/// A stream reporting the combined state of the current media item and its
/// current position.
Stream<MediaState> get mediaStateStream {
  final audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
  final playback = GetIt.instance<PlaybackController>();
  return Rx.combineLatest3<MediaItem?, PlaybackState, FadeDirection, MediaState>(
    playback.mediaItem,
    playback.playbackState,
    audioHandler.fadeState.map((x) => x.fadeDirection).distinct(),
    (mediaItem, playbackState, fadeState) => MediaState(mediaItem, playbackState, fadeState),
  );
}

final mediaStateProvider = StreamProvider.autoDispose<MediaState>((_) => mediaStateStream).select((v) {
  final audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
  final playback = GetIt.instance<PlaybackController>();
  return v.valueOrNull ??
      MediaState(
        playback.mediaItem.valueOrNull,
        playback.playbackState.value,
        audioHandler.fadeState.value.fadeDirection,
      );
});
