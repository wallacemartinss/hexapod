import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/settings.dart';

Future<void> showSettingsSheet(BuildContext context) => showModalBottomSheet<void>(
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
    await ref.read(settingsProvider.notifier).update(_s.copyWith(host: _host.text.trim()));
    if (mounted) Navigator.pop(context);
  }

  Widget _slider(String label, String help, double value, double min, double max, ValueChanged<double> f) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 170,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(color: Colors.white)),
                  Text(help, style: const TextStyle(color: Colors.white54, fontSize: 11)),
                ],
              ),
            ),
            Expanded(
              child: Slider(value: value, min: min, max: max, onChanged: (v) => setState(() => f(v))),
            ),
            SizedBox(
              width: 44,
              child: Text('${(value * 100).round()}%', style: const TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final hello = ref.watch(helloProvider).value;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, 16, 24, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Text(
                    'Ajustes',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
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
                  helperText: 'hexapod.local na rede de casa, ou o nome/IP do Tailscale',
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
                title: const Text('Canhoto', style: TextStyle(color: Colors.white)),
                subtitle: const Text('Troca os joysticks de lado', style: TextStyle(color: Colors.white54)),
                value: _s.swapSticks,
                onChanged: (v) => setState(() => _s = _s.copyWith(swapSticks: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Vibração', style: TextStyle(color: Colors.white)),
                value: _s.haptics,
                onChanged: (v) => setState(() => _s = _s.copyWith(haptics: v)),
              ),
              const Divider(color: Colors.white12),
              Text(
                hello == null
                    ? 'Robô: não conectado'
                    : 'Firmware ${hello.firmwareVersion} · protocolo ${hello.protocolVersion}',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
