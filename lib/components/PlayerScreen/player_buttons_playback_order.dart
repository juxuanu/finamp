import 'package:finamp/components/Shortcuts/global_shortcut_manager.dart';
import 'package:finamp/components/Shortcuts/music_control_shortcuts.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/feedback_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/playback/playback_backend.dart';
import 'package:finamp/services/playback/playback_controller.dart';
import 'package:finamp/utils/locale_helper.dart';
import 'package:finamp/utils/platform_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class PlayerButtonsPlaybackOrder extends ConsumerWidget {
  final audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
  final _playback = GetIt.instance<PlaybackController>();

  PlayerButtonsPlaybackOrder({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A remote-controlled session may not support changing the playback order
    if (!ref.watch(PlaybackController.backendProvider).supports(PlaybackCapability.setShuffle)) {
      return const SizedBox.shrink();
    }

    return StreamBuilder(
      stream: _playback.playbackOrder,
      initialData: _playback.playbackOrder.value,
      builder: (BuildContext context, snapshot) {
        final shortcutHint = GlobalShortcuts.getDisplay(TogglePlaybackOrderIntent);
        final playbackOrderHint = getLocalizedPlaybackOrder(context, _playback.playbackOrder.value);
        return IconButton(
          tooltip: getStringComponentsInLocaleOrder(context, [
            playbackOrderHint,
            if (isDesktop) "($shortcutHint)",
          ], separator: "\n"),
          onPressed: () async {
            FeedbackHelper.feedback(FeedbackType.light);
            await _playback.togglePlaybackOrder();
          },
          icon: Icon(
            (snapshot.data! == FinampPlaybackOrder.shuffled ? TablerIcons.arrows_shuffle : TablerIcons.arrows_right),
          ),
        );
      },
    );
  }

  String getLocalizedPlaybackOrder(BuildContext context, FinampPlaybackOrder playbackOrder) {
    switch (playbackOrder) {
      case FinampPlaybackOrder.linear:
        return AppLocalizations.of(context)!.playbackOrderLinearButtonTooltip;
      case FinampPlaybackOrder.shuffled:
        return AppLocalizations.of(context)!.playbackOrderShuffledButtonTooltip;
    }
  }
}
