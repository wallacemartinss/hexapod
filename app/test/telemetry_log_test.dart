import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hexapod_app/core/proto.dart' as pb;
import 'package:hexapod_app/features/data/telemetry_log.dart';
import 'package:hexapod_app/l10n/l10n.dart';

pb.Telemetry _t(int seq, {int faults = 0}) => pb.Telemetry()
  ..seq = seq
  ..faultFlags = faults;

void main() {
  test('rate, received and seq gaps counted as losses', () {
    final log = TelemetryLog();
    var at = Duration.zero;
    for (final seq in [1, 2, 3, 6, 7]) {
      // 3 → 6: two lost
      log.add(at, _t(seq));
      at += const Duration(milliseconds: 100);
    }
    expect(log.received, 5);
    expect(log.lost, 2);
    expect(log.rateHz(at), 2.5); // 5 in the last 2 s
  });

  test('an ESP32 reset (seq starts over) is not a loss', () {
    final log = TelemetryLog()
      ..add(Duration.zero, _t(5000))
      ..add(const Duration(milliseconds: 100), _t(1));
    expect(log.lost, 0);
  });

  test('keeps only the chart window', () {
    final log = TelemetryLog(window: const Duration(seconds: 1));
    for (var i = 0; i < 30; i++) {
      log.add(Duration(milliseconds: 100 * i), _t(i + 1));
    }
    final s = log.series(const Duration(milliseconds: 2900), (t) => t.seq.toDouble());
    expect(s.length, lessThanOrEqualTo(11));
    expect(s.last.$1, 0); // newest sample is "now"
  });

  test('a part is present while its fault bit is clear', () {
    final t = _t(1, faults: 4 | 8 | 32); // the bench board today
    expect(Part.imu.presentIn(t), isFalse);
    expect(Part.distance.presentIn(t), isFalse);
    expect(Part.power.presentIn(t), isFalse);
    expect(Part.environment.presentIn(t), isTrue);
    expect(Part.servosLeft.presentIn(t), isTrue);
  });

  test('part labels, checks and Wi-Fi signal follow the language', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final pt = lookupAppLocalizations(const Locale('pt'));
    expect(Part.gas.label(en), 'Gas and smoke');
    expect(Part.gas.label(pt), 'Gás e fumaça');
    expect(faultChecks(en).length, faultTexts(en).length);
    expect(faultTexts(pt).first.$2, 'Servos esquerdos (PCA9685 0x40) sem resposta');
    expect(describeSignal(en, -55), '-55 dBm · great');
    expect(describeSignal(pt, -75), '-75 dBm · fraco');
    expect(describeSignal(en, 0), 'no Wi-Fi');
  });

  test('uptime reads like a person would say it', () {
    expect(formatUptime(45000), '45 s');
    expect(formatUptime(192000), '3 min 12 s');
    expect(formatUptime(3720000), '1 h 02 min');
  });
}
