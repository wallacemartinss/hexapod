import '../../core/proto.dart' as pb;
import '../../l10n/l10n.dart';

/// The robot's sensors and boards, each with the Telemetry.fault_flags bit
/// the ESP32 sets while that part does not answer.
enum Part {
  servosLeft('PCA9685 0x40', 1),
  servosRight('PCA9685 0x41', 2),
  imu('BNO085', 4),
  distance('4x VL53L0X', 8),
  environment('BME280', 16),
  power('INA226', 32),
  gas('MQ-2', 2048);

  const Part(this.chip, this.fault);

  final String chip;
  final int fault;

  /// What the part is, in words (card titles).
  String label(AppLocalizations l) => switch (this) {
    servosLeft => l.partServosLeft,
    servosRight => l.partServosRight,
    imu => l.partImu,
    distance => l.partDistance,
    environment => l.partEnvironment,
    power => l.partPower,
    gas => l.partGas,
  };

  /// The part answers (its fault bit is clear).
  bool presentIn(pb.Telemetry t) => t.faultFlags & fault == 0;
}

/// Every fault bit with its text, for the system tab.
List<(int, String)> faultTexts(AppLocalizations l) => [
  (1, l.dataFaultLeftServos),
  (2, l.dataFaultRightServos),
  (4, l.dataFaultImu),
  (8, l.dataFaultDistance),
  (16, l.dataFaultEnvironment),
  (32, l.dataFaultPower),
  (64, l.dataFaultOvercurrent),
  (128, l.faultBatteryLow),
  (256, l.dataFaultBatteryCritical),
  (512, l.dataFaultLoopOverrun),
  (1024, l.dataFaultCalibration),
  (2048, l.dataFaultGas),
];

/// Health checks for the system tab: (fault bit, what is checked). A clear
/// bit means the check passes.
List<(int, String)> faultChecks(AppLocalizations l) => [
  (1, l.checkLeftServos),
  (2, l.checkRightServos),
  (4, l.checkImu),
  (8, l.checkDistance),
  (16, l.checkEnvironment),
  (32, l.checkPower),
  (64, l.checkCurrent),
  (128, l.checkBatteryLow),
  (256, l.checkBatteryCritical),
  (512, l.checkLoop),
  (1024, l.checkCalibration),
  (2048, l.checkGas),
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

/// "1 h 02 min", "3 min 12 s", "45 s" (unit symbols, the same in every
/// language the app speaks).
String formatUptime(int ms) {
  final s = ms ~/ 1000;
  if (s >= 3600) return '${s ~/ 3600} h ${(s % 3600 ~/ 60).toString().padLeft(2, '0')} min';
  if (s >= 60) return '${s ~/ 60} min ${(s % 60).toString().padLeft(2, '0')} s';
  return '$s s';
}

/// Recent PiStatus samples (every 2 s) for the Raspberry Pi charts.
class PiLog {
  PiLog({this.window = const Duration(minutes: 2)});

  final Duration window;
  final _samples = <(Duration, pb.PiStatus)>[];

  void add(Duration at, pb.PiStatus s) {
    _samples.add((at, s));
    while (_samples.isNotEmpty && at - _samples.first.$1 > window) {
      _samples.removeAt(0);
    }
  }

  /// When the last sample arrived (null: none yet).
  Duration? get lastAt => _samples.isEmpty ? null : _samples.last.$1;
  pb.PiStatus? get last => _samples.isEmpty ? null : _samples.last.$2;

  List<(double, double)> series(Duration now, double Function(pb.PiStatus) value) => [
    for (final (at, s) in _samples) (-(now - at).inMilliseconds / 1000, value(s)),
  ];
}

/// "-55 dBm · good": Wi-Fi signal in words a beginner understands.
String describeSignal(AppLocalizations l, int dbm) {
  if (dbm == 0) return l.dataSignalNone;
  final word = dbm >= -60
      ? l.dataSignalGreat
      : (dbm >= -70 ? l.dataSignalGood : (dbm >= -80 ? l.dataSignalWeak : l.dataSignalVeryWeak));
  return '$dbm dBm · $word';
}
