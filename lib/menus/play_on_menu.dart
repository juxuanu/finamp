import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/components/themed_bottom_sheet.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/menus/components/icon_button_with_semantics.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/feedback_helper.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_sticky_header/flutter_sticky_header.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

const playOnMenuRouteName = "/play-on-menu";

/// The other Jellyfin sessions of the current user that can be remote-controlled.
/// Resolves to an empty list when offline or when the sessions can't be fetched.
final AutoDisposeFutureProvider<List<SessionInfo>> controllableSessionsProvider = FutureProvider.autoDispose((
  ref,
) async {
  if (ref.watch(finampSettingsProvider.isOffline)) return [];
  try {
    return await GetIt.instance<JellyfinApiHelper>().getControllableSessions();
  } catch (_) {
    return [];
  }
});

/// App bar button opening the "Play On" menu. Only shown when there is at least one controllable session.
class PlayOnButton extends ConsumerWidget {
  const PlayOnButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasSessions = ref.watch(controllableSessionsProvider).valueOrNull?.isNotEmpty ?? false;
    if (!hasSessions) return const SizedBox.shrink();
    return IconButtonWithSemantics(
      label: AppLocalizations.of(context)!.playOnMenuTitle,
      icon: TablerIcons.cast,
      iconSize: 28.0,
      onPressed: () => showPlayOnMenu(context: context),
    );
  }
}

Future<void> showPlayOnMenu({required BuildContext context}) async {
  await showThemedBottomSheet<void>(
    context: context,
    routeName: playOnMenuRouteName,
    minDraggableHeight: 0.2,
    buildSlivers: (context) {
      final menu = [
        SliverStickyHeader(
          header: Padding(
            padding: const EdgeInsets.only(top: 6.0, bottom: 16.0),
            child: Center(
              child: Text(
                AppLocalizations.of(context)!.playOnMenuTitle,
                style: TextStyle(
                  color: Theme.of(context).textTheme.bodyLarge!.color!,
                  fontSize: 18,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ),
          sliver: const PlayOnSessionList(),
        ),
      ];
      return (MediaQuery.heightOf(context) * 0.4, menu);
    },
  );
}

/// Lists the other Jellyfin sessions of the current user and lets the user
/// remote-control them ("Play On"), or send the current queue to them.
class PlayOnSessionList extends ConsumerWidget {
  const PlayOnSessionList({super.key});

  Future<void> _sendCommand(SessionInfo session, String command) async {
    try {
      await GetIt.instance<JellyfinApiHelper>().sendPlaystateCommand(sessionId: session.id!, command: command);
      FeedbackHelper.feedback(FeedbackType.selection);
    } catch (e) {
      GlobalSnackbar.error(e);
    }
  }

  Future<void> _transferQueue(SessionInfo session) async {
    final queueService = GetIt.instance<QueueService>();
    final audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
    // Item ids are sent as a query parameter, so cap the amount to keep the URL short enough
    final itemIds = queueService.peekQueue(current: true).take(200).map((queueItem) => queueItem.baseItemId).toList();
    if (itemIds.isEmpty) return;
    try {
      final startPosition = audioHandler.playbackPosition;
      await audioHandler.pause();
      await GetIt.instance<JellyfinApiHelper>().playOnSession(
        sessionId: session.id!,
        itemIds: itemIds,
        startPosition: startPosition,
      );
      FeedbackHelper.feedback(FeedbackType.success);
      GlobalSnackbar.message(
        (context) => AppLocalizations.of(context)!.playOnQueueTransferred(session.deviceName ?? session.client ?? ""),
        isConfirmation: true,
      );
    } catch (e) {
      GlobalSnackbar.error(e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(controllableSessionsProvider);
    if (sessions.isLoading) {
      return const SliverToBoxAdapter(child: Center(heightFactor: 2.0, child: CircularProgressIndicator.adaptive()));
    }
    final sessionList = sessions.valueOrNull ?? [];
    if (sessionList.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            AppLocalizations.of(context)!.playOnNoSessionsFound,
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return SliverList(
      delegate: SliverChildBuilderDelegate((context, index) {
        final session = sessionList[index];
        final nowPlaying = session.nowPlayingItem?.name;
        return ListTile(
          leading: Container(
            padding: const EdgeInsets.all(16.0),
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
            child: const Icon(TablerIcons.devices),
          ),
          title: Text(session.deviceName ?? session.client ?? ""),
          subtitle: Text(
            nowPlaying == null
                ? session.client ?? ""
                : AppLocalizations.of(context)!.playOnSessionSubtitle(session.client ?? "", nowPlaying),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(TablerIcons.player_skip_back),
                tooltip: AppLocalizations.of(context)!.skipToPreviousTrackButtonTooltip,
                onPressed: () => _sendCommand(session, "PreviousTrack"),
              ),
              IconButton(
                icon: const Icon(TablerIcons.player_play),
                tooltip: AppLocalizations.of(context)!.togglePlaybackButtonTooltip,
                onPressed: () => _sendCommand(session, "PlayPause"),
              ),
              IconButton(
                icon: const Icon(TablerIcons.player_skip_forward),
                tooltip: AppLocalizations.of(context)!.skipToNextTrackButtonTooltip,
                onPressed: () => _sendCommand(session, "NextTrack"),
              ),
              IconButton(
                icon: const Icon(TablerIcons.cast),
                tooltip: AppLocalizations.of(context)!.playOnTransferQueueTooltip,
                onPressed: () => _transferQueue(session),
              ),
            ],
          ),
        );
      }, childCount: sessionList.length),
    );
  }
}
