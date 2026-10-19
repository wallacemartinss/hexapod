// The app's screens in every language, for the README:
//   make screenshots   (writes docs/screenshots/<lang>/*.png)
// A simulated robot with every sensor fitted, so no real data (home
// location, Wi-Fi names) ends up in the pictures. Tagged `golden`: CI skips it.
@Tags(['golden'])
library;

import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hexapod_app/core/control/control_state.dart';
import 'package:hexapod_app/core/input/gamepad_interpreter.dart';
import 'package:hexapod_app/core/input/gamepad_service.dart';
import 'package:hexapod_app/core/link/robot_link.dart';
import 'package:hexapod_app/core/proto.dart' as pb;
import 'package:hexapod_app/core/providers.dart';
import 'package:hexapod_app/core/robots.dart';
import 'package:hexapod_app/core/settings.dart';
import 'package:hexapod_app/features/brand/brand.dart';
import 'package:hexapod_app/features/data/data_screen.dart';
import 'package:hexapod_app/features/pilot/pilot_screen.dart';
import 'package:hexapod_app/features/robots/pair_screen.dart';
import 'package:hexapod_app/features/robots/robots_sheet.dart';
import 'package:hexapod_app/features/settings/controller_sheet.dart';
import 'package:hexapod_app/features/settings/settings_sheet.dart';
import 'package:hexapod_app/features/video/video_view.dart';

import 'helpers/app.dart';

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

/// A robot walking with every sensor answering.
pb.Telemetry _telemetry(int seq, pb.State state) => pb.Telemetry()
  ..seq = seq
  ..uptimeMs = 754000
  ..state = state
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
  ..distancesMm.addAll([420, 1300, 1650, 900])
  ..temperatureC = 24.6
  ..humidityPct = 58
  ..pressureHpa = 1013
  ..esp32TemperatureC = 41.3
  ..gasLevelPct = 21
  ..loopTimeUs = 330 + (seq % 7) * 20
  ..jointAnglesDeg.addAll([
    for (var i = 0; i < 18; i++) (i % 3 == 0 ? 2.5 * (i - 8) : (i % 3 == 1 ? 35.2 : -106.8)),
  ]);

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
  ..uptimeS = Int64(30843)
  ..wifiRssiDbm = -55;

/// Praça da Sé, São Paulo: a public square, not anyone's home.
final _position = pb.Position()
  ..fix = true
  ..latitudeDeg = -23.550512
  ..longitudeDeg = -46.633310
  ..altitudeM = 762
  ..speedMps = 0.4
  ..courseDeg = 92
  ..satellitesUsed = 8
  ..satellitesInView = 11
  ..hdop = 1.1
  ..utcMs = Int64(1792364405000);

class _FixedControl extends ControlNotifier {
  _FixedControl(this.initial);

  final ControlState initial;

  @override
  ControlState build() => initial;
}

const _robots = RobotsState(
  robots: [
    Robot(id: 'K7F2', name: 'Aranha', token: 'demo', address: '10.42.0.1'),
    Robot(id: 'Q3ZD', name: 'Bancada', token: 'demo'),
  ],
  activeId: 'K7F2',
);

Future<void> _pump(
  WidgetTester tester,
  String lang, {
  ControlState control = const ControlState(scheme: Scheme.walk),
  pb.State state = pb.State.STATE_NORMAL,
  bool onboarded = true,
  Widget home = const PilotScreen(),
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(2400, 1080); // 20:9 phone, landscape
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  var seq = 0;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        commandLoopProvider.overrideWith((ref) {}),
        gamepadServiceProvider.overrideWith((ref) => GamepadInterpreter(ref.read(controlProvider.notifier))),
        controllerPlatformProvider.overrideWith((ref) => null),
        videoViewProvider.overrideWith(
          (ref) =>
              (_) => const VideoPlaceholder(),
        ),
        linkStatusProvider.overrideWith((ref) => Stream.value(LinkStatus.connected)),
        telemetryProvider.overrideWith(
          (ref) => Stream.periodic(const Duration(milliseconds: 100), (_) => _telemetry(++seq, state)),
        ),
        helloProvider.overrideWith(
          (ref) => Stream.value(
            pb.Hello()
              ..firmwareVersion = 'v0.7.0'
              ..hexdVersion = 'v0.7.0'
              ..protocolVersion = 1,
          ),
        ),
        positionProvider.overrideWith(
          (ref) => Stream.periodic(const Duration(seconds: 1), (_) => GpsReading(_position)),
        ),
        piStatusProvider.overrideWith(
          (ref) => Stream.periodic(const Duration(seconds: 2), (n) => PiReading(_pi(n))),
        ),
        controlProvider.overrideWith(() => _FixedControl(control)),
        settingsProvider.overrideWith(() => SettingsNotifier(Settings(onboarded: onboarded, language: lang))),
        robotsProvider.overrideWith(() => RobotsNotifier(_robots)),
        robotAddressProvider.overrideWith((ref) async => '10.42.0.1'),
      ],
      child: testApp(
        locale: Locale(lang),
        theme: ThemeData(
          brightness: Brightness.dark,
          fontFamily: 'Roboto',
          colorScheme: ColorScheme.fromSeed(seedColor: Brand.cyan, brightness: Brightness.dark),
        ),
        home: home,
      ),
    ),
  );
  if (!settle) return;
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 100)); // 4 s of history for the charts
  }
}

Future<void> _shot(WidgetTester tester, String lang, String name) async {
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('../../docs/screenshots/$lang/$name.png'));
}

Future<void> _open(WidgetTester tester, Future<void> Function(BuildContext) show) async {
  show(tester.element(find.byType(PilotScreen)));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100)); // the sheet slides in
  }
}

void main() {
  setUpAll(_loadFonts);

  for (final lang in ['en', 'pt']) {
    group(lang, () {
      testWidgets('splash', (tester) async {
        // The splash fades after 1.4 s: no history pumping here.
        await _pump(tester, lang, home: const BrandSplash(child: SizedBox()), settle: false);
        await tester.runAsync(
          () => precacheImage(
            const AssetImage('assets/brand/splash_logo.png'),
            tester.element(find.byType(BrandSplash)),
          ),
        );
        await tester.pump();
        await _shot(tester, lang, 'splash');
        await tester.pump(const Duration(seconds: 3));
      });

      testWidgets('pilot', (tester) async {
        await _pump(tester, lang);
        await _shot(tester, lang, 'pilot');
      });

      testWidgets('pilot: front legs', (tester) async {
        await _pump(tester, lang, control: const ControlState(scheme: Scheme.legs));
        await _shot(tester, lang, 'pilot_legs');
      });

      testWidgets('pilot: failsafe', (tester) async {
        await _pump(tester, lang, state: pb.State.STATE_SAFE_SIT);
        await _shot(tester, lang, 'pilot_failsafe');
      });

      testWidgets('first run tips', (tester) async {
        await _pump(
          tester,
          lang,
          control: const ControlState(),
          state: pb.State.STATE_RELAXED,
          onboarded: false,
        );
        await _shot(tester, lang, 'onboarding');
      });

      testWidgets('data tabs', (tester) async {
        await _pump(tester, lang, home: const DataScreen());
        final tabs = find.descendant(of: find.byType(TabBar), matching: find.byType(Tab));
        const names = [
          'summary',
          'orientation',
          'distance',
          'position',
          'environment',
          'legs',
          'system',
          'pi',
        ];
        for (var i = 0; i < names.length; i++) {
          await tester.tap(tabs.at(i));
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          await _shot(tester, lang, 'data_${names[i]}');
        }
      });

      testWidgets('settings', (tester) async {
        await _pump(tester, lang);
        await _open(tester, showSettingsSheet);
        await _shot(tester, lang, 'settings');
      });

      testWidgets('my robots', (tester) async {
        await _pump(tester, lang);
        await _open(tester, showRobotsSheet);
        await _shot(tester, lang, 'robots');
      });

      testWidgets('external controller', (tester) async {
        await _pump(tester, lang);
        await _open(tester, showControllerSheet);
        await _shot(tester, lang, 'controller');
      });

      testWidgets('pairing', (tester) async {
        // A dim gradient stands in for the camera (no camera under test).
        await _pump(
          tester,
          lang,
          home: const PairScreen(
            camera: true,
            scanner: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF2A2F38), Color(0xFF14171C)],
                ),
              ),
            ),
          ),
        );
        await _shot(tester, lang, 'pairing');
      });
    });
  }
}
