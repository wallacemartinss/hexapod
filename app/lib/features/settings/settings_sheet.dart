import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/link/robot_link.dart';
import '../../core/proto.dart';
import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../core/robots.dart';
import '../../core/version.dart';
import '../robots/robot_network_screen.dart';
import '../robots/robots_sheet.dart';
import 'controller_sheet.dart';

Future<void> showSettingsSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF15181D),
      builder: (_) => const _SettingsSheet(),
    );

class _SettingsSheet extends ConsumerStatefulWidget {
  const _SettingsSheet();

  @override
  ConsumerState<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends ConsumerState<_SettingsSheet> {
  late Settings _s = ref.read(settingsProvider);
  late final _host = TextEditingController(text: _s.host);

  @override
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await ref
        .read(settingsProvider.notifier)
        .update(_s.copyWith(host: _host.text.trim()));
    if (mounted) Navigator.pop(context);
  }

  Widget _slider(
    String label,
    String help,
    double value,
    double min,
    double max,
    ValueChanged<double> f,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(
          width: 170,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(color: Colors.white)),
              Text(
                help,
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ],
          ),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            onChanged: (v) => setState(() => f(v)),
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            '${(value * 100).round()}%',
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final hello = ref.watch(helloProvider).value;
    final connected =
        ref.watch(linkStatusProvider).value == LinkStatus.connected;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          16,
          24,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Text(
                    'Ajustes',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  FilledButton(onPressed: _save, child: const Text('Salvar')),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _host,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Endereço do robô',
                  helperText:
                      'hexapod.local na rede de casa, ou o nome/IP do Tailscale',
                ),
              ),
              const SizedBox(height: 12),
              _slider(
                'Zona morta',
                'Ignora toques leves no centro',
                _s.deadzone,
                0,
                0.3,
                (v) => _s = _s.copyWith(deadzone: v),
              ),
              _slider(
                'Suavidade (expo)',
                'Mais controle fino perto do centro',
                _s.expo,
                0,
                1,
                (v) => _s = _s.copyWith(expo: v),
              ),
              _slider(
                'Velocidade máxima',
                'Limite para iniciantes e lugares apertados',
                _s.maxSpeed,
                0.2,
                1,
                (v) => _s = _s.copyWith(maxSpeed: v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Canhoto',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: const Text(
                  'Troca os joysticks de lado',
                  style: TextStyle(color: Colors.white54),
                ),
                value: _s.swapSticks,
                onChanged: (v) =>
                    setState(() => _s = _s.copyWith(swapSticks: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Vibração',
                  style: TextStyle(color: Colors.white),
                ),
                value: _s.haptics,
                onChanged: (v) => setState(() => _s = _s.copyWith(haptics: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Esconder altura e modos',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: const Text(
                  'Somem enquanto você pilota; um toque na tela traz de volta',
                  style: TextStyle(color: Colors.white54),
                ),
                value: _s.autoHideBars,
                onChanged: (v) =>
                    setState(() => _s = _s.copyWith(autoHideBars: v)),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.smart_toy_rounded,
                  color: Colors.white70,
                ),
                title: const Text(
                  'Meus robôs',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: const Text(
                  'Parear um robô novo ou escolher qual pilotar',
                  style: TextStyle(color: Colors.white54),
                ),
                trailing: const Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.white54,
                ),
                onTap: () {
                  final nav = Navigator.of(context)..pop();
                  showRobotsSheet(nav.context);
                },
              ),
              if (ref.watch(robotsProvider).active != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.wifi_rounded,
                    color: Colors.white70,
                  ),
                  title: const Text(
                    'Rede do robô (Wi-Fi)',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: const Text(
                    'Rede de casa ou direto com o celular; nome do robô',
                    style: TextStyle(color: Colors.white54),
                  ),
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.white54,
                  ),
                  onTap: () {
                    final nav = Navigator.of(context)..pop();
                    showRobotNetworkScreen(nav.context);
                  },
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.sports_esports_rounded,
                  color: Colors.white70,
                ),
                title: const Text(
                  'Controle externo',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: const Text(
                  'Parear o controle de PS5 e ver os botões',
                  style: TextStyle(color: Colors.white54),
                ),
                trailing: const Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.white54,
                ),
                onTap: () {
                  // Close this sheet first (it holds unsaved edits of its own);
                  // the navigator's context outlives it.
                  final nav = Navigator.of(context)..pop();
                  showControllerSheet(nav.context);
                },
              ),
              const Divider(color: Colors.white12),
              Text(
                'App $appVersion\n${robotVersions(hello, connected: connected)}',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Robot software line in the settings: ESP32 firmware, hexd (the bridge on
/// the Pi) and protocol versions.
String robotVersions(Hello? hello, {required bool connected}) {
  if (!connected) return 'Robô: não conectado';
  if (hello == null) return 'Robô: conectado, aguardando as versões…';
  final firmware = hello.firmwareVersion.isEmpty
      ? 'aguardando o ESP32'
      : hello.firmwareVersion;
  final bridge = hello.hexdVersion.isEmpty
      ? ''
      : ' · ponte (Pi) ${hello.hexdVersion}';
  return 'Robô: firmware $firmware$bridge · protocolo ${hello.protocolVersion}';
}
