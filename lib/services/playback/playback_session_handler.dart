// The overridden methods deliberately don't forward to the wrapped player: they go to the active backend instead.
// ignore_for_file: must_call_super

import 'package:audio_service/audio_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/playback/playback_controller.dart';
import 'package:rxdart/rxdart.dart';

/// The audio handler registered with the OS media session (notification, lock
/// screen, headset buttons, Android Auto, CarPlay).
///
/// Transport commands and the shown state go to the [PlaybackController], so
/// the OS controls whatever Finamp is controlling. Everything else (content
/// browsing, ratings, the OS queue) stays with this device's player.
class PlaybackSessionHandler extends CompositeAudioHandler {
  PlaybackSessionHandler({required PlaybackController controller, required MusicPlayerBackgroundTask player})
    : _controller = controller,
      super(player);

  final PlaybackController _controller;

  @override
  ValueStream<PlaybackState> get playbackState => _controller.playbackState;
  @override
  ValueStream<MediaItem?> get mediaItem => _controller.mediaItem;

  @override
  Future<void> play() => _controller.play();
  @override
  Future<void> pause() => _controller.pause();
  @override
  Future<void> stop() => _controller.stop();
  @override
  Future<void> skipToNext() => _controller.skipToNext();
  @override
  Future<void> skipToPrevious() => _controller.skipToPrevious();
  @override
  Future<void> seek(Duration position) => _controller.seek(position);
  @override
  Future<void> fastForward() => _seekBy(AudioService.config.fastForwardInterval);
  @override
  Future<void> rewind() => _seekBy(-AudioService.config.rewindInterval);

  @override
  Future<void> click([MediaButton button = MediaButton.media]) => switch (button) {
    MediaButton.media => _controller.togglePlayback(),
    MediaButton.next => _controller.skipToNext(),
    MediaButton.previous => _controller.skipToPrevious(),
  };

  Future<void> _seekBy(Duration offset) {
    final position = (playbackState.valueOrNull?.position ?? Duration.zero) + offset;
    return _controller.seek(position < Duration.zero ? Duration.zero : position);
  }
}
