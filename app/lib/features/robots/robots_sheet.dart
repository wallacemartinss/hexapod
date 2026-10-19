import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/robots.dart';
import '../../l10n/l10n.dart';
import 'pair_screen.dart';
import 'robot_network_screen.dart';

const _ok = Color(0xFF3DDC97);

Future<void> showRobotsSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: const Color(0xFF15181D),
  builder: (_) => const RobotsSheet(),
);

/// "My robots": which paired robot the app drives, forget one, add one.
class RobotsSheet extends ConsumerWidget {
  const RobotsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(robotsProvider);
    final notifier = ref.read(robotsProvider.notifier);
    final l = context.l10n;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  l.robotsTitle,
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: () {
                    final nav = Navigator.of(context)..pop();
                    showPairScreen(nav.context);
                  },
                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                  label: Text(l.robotsNew),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (state.robots.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(l.robotsEmpty, style: const TextStyle(color: Colors.white70)),
              ),
            for (final r in state.robots)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  r.id == state.activeId
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: r.id == state.activeId ? _ok : Colors.white54,
                ),
                title: Text(r.name, style: const TextStyle(color: Colors.white)),
                subtitle: Text(
                  'ID ${r.id}${r.address == null ? '' : ' · ${r.address}'}',
                  style: const TextStyle(color: Colors.white54),
                ),
                onTap: () => notifier.select(r.id),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (r.id == state.activeId)
                      IconButton(
                        tooltip: l.robotsNetworkAndName,
                        icon: const Icon(Icons.settings_rounded, color: Colors.white70),
                        onPressed: () {
                          final nav = Navigator.of(context)..pop();
                          showRobotNetworkScreen(nav.context);
                        },
                      ),
                    IconButton(
                      tooltip: l.robotsForget,
                      icon: const Icon(Icons.delete_outline_rounded, color: Colors.white54),
                      onPressed: () async {
                        final yes = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: Text(l.robotsForgetTitle(r.name)),
                            content: Text(l.robotsForgetText),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(c, false),
                                child: Text(l.robotsCancel),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(c, true),
                                child: Text(l.robotsForget),
                              ),
                            ],
                          ),
                        );
                        if (yes == true) await notifier.forget(r.id);
                      },
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
