import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/components/themed_bottom_sheet.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/menus/components/icon_button_with_semantics.dart';
import 'package:finamp/menus/output_menu.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/feedback_helper.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/playon_service.dart';
import 'package:finamp/services/remote_control_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_sticky_header/flutter_sticky_header.dart';
import 'package:get_it/get_it.dart';

const playOnMenuRouteName = "/play-on-menu";

/// The other Jellyfin sessions of the current user that can be remote-controlled.
/// Resolves to an empty list when offline or when the sessions can't be fetched.
/// Fetched when first watched, when the app returns to the foreground and when the Play On menu opens.
final AutoDisposeFutureProvider<List<SessionInfo>> controllableSessionsProvider = FutureProvider.autoDispose((
  ref,
) async {
  final lifecycleListener = AppLifecycleListener(onResume: ref.invalidateSelf);
  ref.onDispose(lifecycleListener.dispose);
  if (ref.watch(finampSettingsProvider.isOffline)) return [];
  try {
    return await GetIt.instance<JellyfinApiHelper>().getControllableSessions();
  } catch (_) {
    return [];
  }
});

/// App bar button opening the "Play On" menu. Only shown when there is at least
/// one controllable session, or while a session is being controlled.
class PlayOnButton extends ConsumerWidget {
  const PlayOnButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isControlling = ref.watch(RemoteControlService.controlledSessionProvider) != null;
    final hasSessions = ref.watch(controllableSessionsProvider).valueOrNull?.isNotEmpty ?? false;
    if (!isControlling && !hasSessions) return const SizedBox.shrink();
    return IconButtonWithSemantics(
      label: AppLocalizations.of(context)!.playOnMenuTitle,
      icon: isControlling ? Icons.cast_connected : Icons.cast,
      iconSize: 28.0,
      onPressed: () => showPlayOnMenu(context: context),
    );
  }
}

Future<void> showPlayOnMenu({required BuildContext context}) async {
  // Show up-to-date sessions whenever the menu is opened
  GetIt.instance<ProviderContainer>().invalidate(controllableSessionsProvider);
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
        const SliverToBoxAdapter(child: PlayOnVolumeSlider()),
      ];
      return (MediaQuery.heightOf(context) * 0.5, menu);
    },
  );
}

/// Lists the other Jellyfin sessions of the current user. Tapping a session
/// starts controlling it, tapping the controlled session again releases it.
class PlayOnSessionList extends ConsumerWidget {
  const PlayOnSessionList({super.key});

  Future<void> _toggleControl(SessionInfo session, bool isControlled) async {
    final remoteControl = GetIt.instance<RemoteControlService>();
    try {
      if (isControlled) {
        await remoteControl.release();
      } else if (!GetIt.instance<PlayOnService>().isConnected) {
        GlobalSnackbar.message((context) => AppLocalizations.of(context)!.playOnWebsocketRequired);
        return;
      } else {
        await remoteControl.control(session);
      }
      FeedbackHelper.feedback(FeedbackType.selection);
    } catch (e) {
      GlobalSnackbar.error(e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(controllableSessionsProvider);
    final controlledSession = ref.watch(RemoteControlService.controlledSessionProvider);
    if (sessions.isLoading && !sessions.hasValue) {
      return const SliverToBoxAdapter(child: Center(heightFactor: 2.0, child: CircularProgressIndicator.adaptive()));
    }
    final sessionList = [...sessions.valueOrNull ?? <SessionInfo>[]];
    // Always list the controlled session, with its live state
    if (controlledSession != null) {
      sessionList.removeWhere((session) => session.id == controlledSession.id);
      sessionList.insert(0, controlledSession);
    }
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
        final isControlled = session.id == controlledSession?.id;
        final nowPlaying = session.nowPlayingItem?.name;
        return ListTile(
          selected: isControlled,
          selectedColor: Theme.of(context).colorScheme.primary,
          selectedTileColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
          title: Text(session.deviceName ?? session.client ?? ""),
          subtitle: Text(
            nowPlaying == null
                ? session.client ?? ""
                : AppLocalizations.of(context)!.playOnSessionSubtitle(session.client ?? "", nowPlaying),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Icon(isControlled ? Icons.cast_connected : Icons.cast),
          onTap: () => _toggleControl(session, isControlled),
        );
      }, childCount: sessionList.length),
    );
  }
}

/// Volume of the controlled session. Hidden while controlling local playback.
class PlayOnVolumeSlider extends ConsumerWidget {
  const PlayOnVolumeSlider({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controlledSession = ref.watch(RemoteControlService.controlledSessionProvider);
    if (controlledSession == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16.0),
      child: VolumeSlider(
        initialValue: (controlledSession.playState?.volumeLevel ?? 100) / 100.0,
        onChange: (value) => GetIt.instance<RemoteControlService>().setVolume(value),
      ),
    );
  }
}
