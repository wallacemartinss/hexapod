import '../../core/proto.dart' as pb;

/// The robot's sensors and boards, each with the Telemetry.fault_flags bit
/// the ESP32 sets while that part does not answer.
enum Part {
  servosLeft('Servos esquerdos', 'PCA9685 0x40', 1),
  servosRight('Servos direitos', 'PCA9685 0x41', 2),
  imu('Orientação', 'BNO085', 4),
  distance('Distância', '4x VL53L0X', 8),
  environment('Ambiente', 'BME280', 16),
  power('Bateria', 'INA226', 32);

  const Part(this.label, this.chip, this.fault);

  final String label;
  final String chip;
  final int fault;

  /// The part answers (its fault bit is clear).
  bool presentIn(pb.Telemetry t) => t.faultFlags & fault == 0;
}

/// Every fault bit with its text, for the system tab.
const faultTexts = <(int, String)>[
  (1, 'Servos esquerdos (PCA9685 0x40) sem resposta'),
  (2, 'Servos direitos (PCA9685 0x41) sem resposta'),
  (4, 'IMU (BNO085) ausente'),
  (8, 'Sensores de distância (VL53L0X) ausentes'),
  (16, 'Sensor de ambiente (BME280) ausente'),
  (32, 'Medidor de bateria (INA226) ausente'),
  (64, 'Corrente alta por mais de 3 s'),
  (128, 'Bateria baixa: velocidade reduzida'),
  (256, 'Bateria crítica: desligamento pedido'),
  (512, 'Laço de controle atrasado (50 Hz)'),
  (1024, 'Calibração dos servos não carregada'),
];

/// Health checks for the system tab: (fault bit, what is checked). A clear
/// bit means the check passes.
const faultChecks = <(int, String)>[
  (1, 'Servos esquerdos (PCA9685 0x40)'),
  (2, 'Servos direitos (PCA9685 0x41)'),
  (4, 'IMU (BNO085)'),
  (8, 'Distância (4x VL53L0X)'),
  (16, 'Ambiente (BME280)'),
  (32, 'Bateria (INA226)'),
  (64, 'Corrente dentro do limite'),
  (128, 'Bateria acima de 3,5 V por célula'),
  (256, 'Bateria acima de 3,3 V por célula'),
  (512, 'Laço de 50 Hz no prazo'),
  (1024, 'Calibração dos servos carregada'),
];

/// Recent Telemetry received by the app: rate, losses and series for the
/// charts. Fed while the data screen is open.
class TelemetryLog {
  TelemetryLog({this.window = const Duration(seconds: 30)});

  /// How much history the charts keep.
  final Duration window;

  final _samples = <(Duration, pb.Telemetry)>[];
  int _lost = 0;
  int _received = 0;

  void add(Duration at, pb.Telemetry t) {
    if (_samples.isNotEmpty) {
      final gap = t.seq - _samples.last.$2.seq;
      if (gap > 1 && gap < 1000) _lost += gap - 1; // a reset restarts seq: not a loss
    }
    _received++;
    _samples.add((at, t));
    while (_samples.isNotEmpty && at - _samples.first.$1 > window) {
      _samples.removeAt(0);
    }
  }

  pb.Telemetry? get last => _samples.isEmpty ? null : _samples.last.$2;

  /// Telemetry messages lost on the way (gaps in seq), and received.
  int get lost => _lost;
  int get received => _received;

  /// Messages per second over the last two seconds.
  double rateHz(Duration now) {
    const span = Duration(seconds: 2);
    final recent = _samples.where((s) => now - s.$1 <= span).length;
    return recent / (span.inMilliseconds / 1000);
  }

  /// (seconds before [now], value) pairs for a chart.
  List<(double, double)> series(Duration now, double Function(pb.Telemetry) value) => [
    for (final (at, t) in _samples) (-(now - at).inMilliseconds / 1000, value(t)),
  ];
}

/// "1 h 02 min", "3 min 12 s", "45 s".
String formatUptime(int ms) {
  final s = ms ~/ 1000;
  if (s >= 3600) return '${s ~/ 3600} h ${(s % 3600 ~/ 60).toString().padLeft(2, '0')} min';
  if (s >= 60) return '${s ~/ 60} min ${(s % 60).toString().padLeft(2, '0')} s';
  return '$s s';
}
