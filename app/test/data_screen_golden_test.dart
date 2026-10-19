// Captures of each data tab, for design review (see pilot_screen_golden_test).
@Tags(['golden'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'helpers/app.dart';
import 'package:hexapod_app/core/link/robot_link.dart';
import 'package:hexapod_app/core/proto.dart' as pb;
import 'package:hexapod_app/core/providers.dart';
import 'package:hexapod_app/features/data/data_screen.dart';

Future<void> _loadFonts() async {
  final flutterRoot = File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  final fonts = Directory('$flutterRoot/bin/cache/artifacts/material_fonts');
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final bytes = File('${fonts.path}/$f').readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
    }
    await loader.load();
  }

  await load('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
}

/// Every sensor fitted, robot walking.
pb.Telemetry _full(int seq) => pb.Telemetry()
  ..seq = seq
  ..uptimeMs = 754000
  ..state = pb.State.STATE_BLOCKED
  ..mode = pb.Mode.MODE_WALK
  ..gait = pb.Gait.GAIT_TRIPOD
  ..batteryVoltageV = 11.42
  ..batteryCurrentA = 3.8
  ..orientation = (pb.Quaternion()
    ..w = 0.996
    ..x = 0.052
    ..y = -0.07
    ..z = 0.01)
  ..rollDeg = 6.2 + (seq % 20) / 4
  ..pitchDeg = -8.1 + (seq % 13) / 3
  ..yawDeg = 12.5
  ..distancesMm.addAll([130, 820, 1650, 8190])
  ..blockedMask = 1
  ..temperatureC = 24.6
  ..humidityPct = 58
  ..pressureHpa = 1013
  ..esp32TemperatureC = 41.3
  ..gasLevelPct = 21
  ..loopTimeUs = 330 + (seq % 7) * 20
  ..jointAnglesDeg.addAll([
    for (var i = 0; i < 18; i++) (i % 3 == 0 ? 2.5 * (i - 8) : (i % 3 == 1 ? 35.2 : -106.8)),
  ]);

/// The bench board today: no IMU, distance or power sensors.
pb.Telemetry _bench(int seq) => pb.Telemetry()
  ..seq = seq
  ..uptimeMs = 92000
  ..state = pb.State.STATE_NORMAL
  ..mode = pb.Mode.MODE_SIT
  ..faultFlags = 4 | 8 | 32
  ..esp32TemperatureC = 44.0
  ..loopTimeUs = 330
  ..jointAnglesDeg.addAll([for (var i = 0; i < 18; i++) (i % 3 == 1 ? 35.2 : (i % 3 == 2 ? -106.8 : 0.0))]);

/// The Pi at work, after a supply dip (the bench's weak power).
pb.PiStatus _pi(int n) => pb.PiStatus()
  ..cpuPercent = 18.0 + (n % 5) * 4
  ..load1m = 0.42
  ..cpuFreqMhz = 1200
  ..cpuMaxFreqMhz = 1200
  ..temperatureC = 53.7 + (n % 3) * 0.5
  ..memUsedMb = 255
  ..memTotalMb = 905
  ..diskUsedMb = 4100
  ..diskTotalMb = 119300
  ..underVoltageSeen = true
  ..uptimeS = Int64(30843)
  ..wifiRssiDbm = -55;

Future<void> _pump(WidgetTester tester, pb.Telemetry Function(int) telemetry, {pb.Position? position}) async {
  tester.view.physicalSize = const Size(2400, 1080);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  var seq = 0;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        linkStatusProvider.overrideWith((ref) => Stream.value(LinkStatus.connected)),
        positionProvider.overrideWith(
          (ref) => position == null
              ? const Stream.empty()
              : Stream.periodic(const Duration(seconds: 1), (_) => GpsReading(position)),
        ),
        piStatusProvider.overrideWith(
          (ref) => Stream.periodic(const Duration(seconds: 2), (n) => PiReading(_pi(n))),
        ),
        telemetryProvider.overrideWith(
          (ref) => Stream.periodic(const Duration(milliseconds: 100), (_) => telemetry(++seq)),
        ),
        helloProvider.overrideWith(
          (ref) => Stream.value(
            pb.Hello()
              ..firmwareVersion = 'f0eca15'
              ..hexdVersion = 'f0eca15'
              ..protocolVersion = 1,
          ),
        ),
      ],
      child: testApp(
        theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Roboto'),
        home: const DataScreen(),
      ),
    ),
  );
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 100)); // 4 s of history
  }
}

Future<void> _tab(WidgetTester tester, String name, String file) async {
  await tester.tap(find.text(name));
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
  await expectLater(find.byType(DataScreen), matchesGoldenFile('goldens/$file.png'));
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('all sensors', (tester) async {
    await _pump(
      tester,
      _full,
      position: pb.Position()
        ..fix = true
        ..latitudeDeg = -23.550512
        ..longitudeDeg = -46.633310
        ..altitudeM = 762
        ..speedMps = 0.4
        ..courseDeg = 92
        ..satellitesUsed = 8
        ..satellitesInView = 11
        ..hdop = 1.1
        ..utcMs = Int64(1792364405000),
    );
    await _tab(tester, 'Resumo', 'data_summary');
    await _tab(tester, 'Posição', 'data_position');
    await _tab(tester, 'Orientação', 'data_orientation');
    await _tab(tester, 'Distância', 'data_distance');
    await _tab(tester, 'Ambiente', 'data_environment');
    await _tab(tester, 'Pernas', 'data_legs');
    await _tab(tester, 'Sistema', 'data_system');
    // Over 2 min of Pi samples: the charts must keep the old ones inside.
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(seconds: 2));
    }
    await _tab(tester, 'Raspberry Pi', 'data_pi');
    await tester.drag(find.text('Processador'), const Offset(0, -150));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await expectLater(find.byType(DataScreen), matchesGoldenFile('goldens/data_pi_charts.png'));
  });

  testWidgets('bench board: sensors not fitted', (tester) async {
    await _pump(
      tester,
      _bench,
      position: pb.Position()
        ..satellitesInView = 1
        ..utcMs = Int64(1792364405000),
    );
    await _tab(tester, 'Resumo', 'data_bench_summary');
    await _tab(tester, 'Posição', 'data_bench_position');
    await _tab(tester, 'Orientação', 'data_bench_orientation');
  });
}
