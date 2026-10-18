import 'package:flutter/material.dart';

import '../../core/proto.dart' as pb;

enum Severity { ok, info, warning, danger }

/// How a robot state is shown to the pilot: a short label, what happened and
/// what to do about it.
class StateText {
  const StateText(this.label, this.severity, [this.detail, this.action]);

  final String label;
  final Severity severity;
  final String? detail;
  final String? action;
}

StateText describeState(pb.State s) => switch (s) {
  pb.State.STATE_NORMAL => const StateText('Pronto', Severity.ok),
  pb.State.STATE_STOPPING => const StateText(
    'Parando',
    Severity.warning,
    'O sinal do app falhou por um instante.',
    'Segure LEVANTAR para retomar',
  ),
  pb.State.STATE_SAFE_SIT => const StateText(
    'Sentado por segurança',
    Severity.warning,
    'O robô perdeu o sinal e se apoiou nas 6 patas.',
    'Segure LEVANTAR para retomar',
  ),
  pb.State.STATE_RELAXED => const StateText(
    'Relaxado',
    Severity.info,
    'Servos sem força.',
    'Segure LEVANTAR para ficar em pé',
  ),
  pb.State.STATE_BLOCKED => const StateText(
    'Obstáculo',
    Severity.warning,
    'Andar nessa direção está bloqueado; as outras continuam livres.',
  ),
  pb.State.STATE_LOW_BATTERY => const StateText(
    'Bateria crítica',
    Severity.danger,
    'O robô sentou e o Raspberry Pi vai desligar.',
    'Troque ou carregue a bateria',
  ),
  pb.State.STATE_TIPPED => const StateText(
    'Tombou',
    Severity.danger,
    'Inclinação acima de 35°: patas relaxadas.',
    'Desvire o robô e segure LEVANTAR',
  ),
  pb.State.STATE_ESTOP => const StateText(
    'PARADO',
    Severity.danger,
    'Parada de emergência: servos sem força.',
    'Segure LEVANTAR para religar',
  ),
  _ => const StateText('—', Severity.info),
};

/// Fault bits worth telling the pilot (hexapod.v1.Fault).
List<String> describeFaults(int flags) => [
  if (flags & 1 != 0) 'Servos esquerdos sem resposta',
  if (flags & 2 != 0) 'Servos direitos sem resposta',
  if (flags & 4 != 0) 'IMU ausente: sem detecção de queda',
  if (flags & 8 != 0) 'Sensores de distância ausentes',
  if (flags & 16 != 0) 'Sensor de ambiente ausente',
  if (flags & 32 != 0) 'Medidor de bateria ausente',
  if (flags & 64 != 0) 'Corrente alta',
  if (flags & 128 != 0) 'Bateria baixa: velocidade reduzida',
  if (flags & 256 != 0) 'Bateria crítica: desligando',
  if (flags & 512 != 0) 'Laço de controle atrasado',
  if (flags & 1024 != 0) 'Calibração não carregada',
  if (flags & 2048 != 0) 'Sensor de gás ausente',
];

Color severityColor(Severity s) => switch (s) {
  Severity.ok => const Color(0xFF3DDC97),
  Severity.info => const Color(0xFF7FB2FF),
  Severity.warning => const Color(0xFFFFB547),
  Severity.danger => const Color(0xFFFF5A5F),
};

/// 3S LiPo: rough state of charge from the pack voltage (resting curve).
int batteryPercent(double volts) {
  final cell = volts / 3;
  const curve = <(double, int)>[
    (3.30, 0),
    (3.50, 5),
    (3.68, 20),
    (3.74, 35),
    (3.80, 50),
    (3.87, 65),
    (3.95, 80),
    (4.06, 90),
    (4.20, 100),
  ];
  if (cell <= curve.first.$1) return 0;
  for (var i = 1; i < curve.length; i++) {
    final (v1, p1) = curve[i];
    if (cell <= v1) {
      final (v0, p0) = curve[i - 1];
      return (p0 + (p1 - p0) * (cell - v0) / (v1 - v0)).round();
    }
  }
  return 100;
}
