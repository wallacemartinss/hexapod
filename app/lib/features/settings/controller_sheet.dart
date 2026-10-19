import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/input/gamepad_service.dart';
import '../../core/providers.dart';

const _ok = Color(0xFF3DDC97);

Future<void> showControllerSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: const Color(0xFF15181D),
  builder: (_) => const ControllerSheet(),
);

/// External controller: status, pairing steps for the PS5 DualSense, a test
/// buzz and the button map. Changes apply right away (no Save).
class ControllerSheet extends ConsumerWidget {
  const ControllerSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pad = ref.watch(gamepadNameProvider);
    final platform = ref.watch(controllerPlatformProvider);
    final settings = ref.watch(settingsProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Controle externo',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: pad != null ? _ok.withValues(alpha: 0.6) : Colors.white12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.sports_esports_rounded, size: 32, color: pad != null ? _ok : Colors.white38),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            pad != null ? 'Conectado' : 'Nenhum controle conectado',
                            style: TextStyle(
                              color: pad != null ? _ok : Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            pad ?? 'Siga os passos abaixo para parear',
                            style: const TextStyle(color: Colors.white54, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    if (pad != null)
                      OutlinedButton.icon(
                        onPressed: () => ref.read(gamepadServiceProvider).identify(),
                        icon: const Icon(Icons.vibration_rounded, size: 18),
                        label: const Text('Testar'),
                      ),
                    if (platform != null) ...[
                      const SizedBox(width: 8),
                      FilledButton.tonalIcon(
                        onPressed: platform.openBluetoothSettings,
                        icon: const Icon(Icons.bluetooth_rounded, size: 18),
                        label: const Text('Bluetooth'),
                      ),
                    ],
                  ],
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Esconder joysticks da tela', style: TextStyle(color: Colors.white)),
                subtitle: const Text(
                  'Com o controle conectado, o vídeo fica livre. O PARAR continua na tela, '
                  'e os joysticks voltam se o controle desconectar.',
                  style: TextStyle(color: Colors.white54),
                ),
                value: settings.hideSticksWithPad,
                onChanged: (v) =>
                    ref.read(settingsProvider.notifier).update(settings.copyWith(hideSticksWithPad: v)),
              ),
              const Divider(color: Colors.white12),
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  initiallyExpanded: pad == null,
                  iconColor: Colors.white70,
                  collapsedIconColor: Colors.white70,
                  title: const Text(
                    'Como parear o controle de PS5',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                  children: const [
                    _Step(
                      1,
                      'Com o controle desligado, segure PS + Create',
                      'Create é o botão pequeno à esquerda do touchpad. Solte quando a luz piscar rápido, em azul.',
                    ),
                    _Step(
                      2,
                      'Abra o Bluetooth do celular',
                      'Toque em "Bluetooth" aqui em cima e depois em "Parear novo dispositivo".',
                    ),
                    _Step(
                      3,
                      'Escolha "DualSense Wireless Controller"',
                      'Pode aparecer só como "Wireless Controller".',
                    ),
                    _Step(
                      4,
                      'Volte para o app',
                      'O controle vibra duas vezes e o ícone fica verde. Da próxima vez, basta apertar PS.',
                    ),
                  ],
                ),
              ),
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: const ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  iconColor: Colors.white70,
                  collapsedIconColor: Colors.white70,
                  title: Text(
                    'Botões',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                  children: [
                    _Button('Bolinha', 'PARAR'),
                    _Button('Direcional para cima, segurado', 'Levantar'),
                    _Button('Direcional para baixo', 'Sentar'),
                    _Button('Xis / Quadrado / Triângulo', 'Andar / Pose / Patas'),
                    _Button('Sticks', 'Iguais aos joysticks da tela'),
                    _Button('L2 / R2', 'Abaixa / sobe o corpo'),
                    _Button('L1 segurado (Pose)', 'Inclinar o controle inclina o robô'),
                    _Button('L1 / R1 / R3 (Patas)', 'Guarda / Acenar / Golpe'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.n, this.title, this.text);

  final int n;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: const Color(0xFF3FCDF5),
            child: Text(
              '$n',
              style: const TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
                Text(text, style: const TextStyle(color: Colors.white60, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button(this.button, this.action);

  final String button;
  final String action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 230,
            child: Text(button, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ),
          Expanded(
            child: Text(action, style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
