import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/proto.dart';
import '../../core/providers.dart';
import '../../l10n/l10n.dart';
import '../brand/brand.dart';
import 'map_screen.dart';
import 'nav_texts.dart';

/// The GPS mission on the pilot screen: what it does, and Cancel; after a
/// lost link, Resume; with the battery low, Go home. Nothing otherwise.
/// Tapping the text opens the map.
class NavChip extends ConsumerWidget {
  const NavChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(navStatusProvider).value;
    if (st == null) return const SizedBox.shrink();
    final l = context.l10n;
    final send = ref.read(navRequestProvider);
    void act(NavAction a) => send(NavRequest(action: a));
    final mission = navMissionOn(st);
    final String text;
    final (String, NavAction)? button;
    if (mission) {
      text = '${navMissionText(l, st)} · ${navStateText(l, st)}';
      button = (l.followCancel, NavAction.NAV_ACTION_STOP);
    } else if (st.resumable) {
      text = l.navInterrupted;
      button = (l.navResume, NavAction.NAV_ACTION_RESUME);
    } else if (st.batteryLow && st.homeSet) {
      text = l.navBatteryLow;
      button = (l.navGoHome, NavAction.NAV_ACTION_GO_HOME);
    } else if (st.state == NavState.NAV_STATE_OUTSIDE_FENCE) {
      text = l.navStateOutside;
      button = null;
    } else {
      return const SizedBox.shrink();
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Brand.cyan.withValues(alpha: 0.8)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: () => showMapScreen(context),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.map_rounded, color: Brand.cyan, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    text,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (button != null)
              TextButton(
                onPressed: () => act(button!.$2),
                child: Text(
                  button.$1,
                  style: const TextStyle(color: Brand.cyan, fontWeight: FontWeight.w700),
                ),
              )
            else
              const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }
}
