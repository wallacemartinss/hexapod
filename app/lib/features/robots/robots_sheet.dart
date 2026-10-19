import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/robots.dart';
import 'pair_screen.dart';
import 'robot_network_screen.dart';

const _ok = Color(0xFF3DDC97);

Future<void> showRobotsSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: const Color(0xFF15181D),
  builder: (_) => const RobotsSheet(),
);

/// "Meus robôs": which paired robot the app drives, forget one, add one.
class RobotsSheet extends ConsumerWidget {
  const RobotsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(robotsProvider);
    final notifier = ref.read(robotsProvider.notifier);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Meus robôs',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: () {
                    final nav = Navigator.of(context)..pop();
                    showPairScreen(nav.context);
                  },
                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                  label: const Text('Novo robô'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (state.robots.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'Nenhum robô pareado. Toque em "Novo robô" e escaneie o QR da tela do robô.',
                  style: TextStyle(color: Colors.white70),
                ),
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
                        tooltip: 'Rede e nome',
                        icon: const Icon(Icons.settings_rounded, color: Colors.white70),
                        onPressed: () {
                          final nav = Navigator.of(context)..pop();
                          showRobotNetworkScreen(nav.context);
                        },
                      ),
                    IconButton(
                      tooltip: 'Esquecer',
                      icon: const Icon(Icons.delete_outline_rounded, color: Colors.white54),
                      onPressed: () async {
                        final yes = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: Text('Esquecer ${r.name}?'),
                            content: const Text('Para pilotar de novo, será preciso escanear o QR do robô.'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(c, false),
                                child: const Text('Cancelar'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(c, true),
                                child: const Text('Esquecer'),
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
