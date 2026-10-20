// Renders the pilot screen at phone size with real fonts, for design review:
//   flutter test --update-goldens test/pilot_screen_golden_test.dart
// Images land in test/goldens/. Tagged `golden`: CI skips them (pixel output
// varies between machines); they are a local design-review tool.
@Tags(['golden'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'helpers/app.dart';
import 'package:hexapod_app/core/control/control_state.dart';
import 'package:hexapod_app/core/link/robot_link.dart';
import 'package:hexapod_app/core/proto.dart' as pb;
import 'package:hexapod_app/core/providers.dart';
import 'package:hexapod_app/core/settings.dart';
import 'package:hexapod_app/features/pilot/pilot_screen.dart';
import 'package:hexapod_app/features/video/video_view.dart';

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

pb.Telemetry _telemetry(pb.State state, {int faults = 0}) => pb.Telemetry()
  ..state = state
  ..faultFlags = faults
  ..batteryVoltageV = 11.6
  ..distancesMm.addAll([420, 1300, 900, 180])
  ..blockedMask = 0
  ..mode = pb.Mode.MODE_WALK;

Future<void> _pump(
  WidgetTester tester,
  ControlState control,
  pb.Telemetry telemetry, {
  bool onboarded = true,
  double pixelRatio = 2.625,
}) async {
  tester.view.physicalSize = const Size(2400, 1080); // 20:9 phone, landscape
  tester.view.devicePixelRatio = pixelRatio;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        commandLoopProvider.overrideWith((ref) {}),
        targetsProvider.overrideWith((ref) => const Stream<pb.Targets>.empty()),
        followStatusProvider.overrideWith((ref) => const Stream<pb.FollowStatus>.empty()),
        navStatusProvider.overrideWith((ref) => const Stream<pb.NavStatus>.empty()),
        piStatusProvider.overrideWith((ref) => const Stream.empty()),
        videoViewProvider.overrideWith(
          (ref) =>
              (_) => const VideoPlaceholder(),
        ),
        linkStatusProvider.overrideWith((ref) => Stream.value(LinkStatus.connected)),
        telemetryProvider.overrideWith(
          (ref) => Stream.periodic(const Duration(milliseconds: 100), (_) => telemetry),
        ),
        helloProvider.overrideWith((ref) => const Stream.empty()),
        controlProvider.overrideWith(() => _FixedControl(control)),
        settingsProvider.overrideWith(() => SettingsNotifier(Settings(onboarded: onboarded))),
        robotAddressProvider.overrideWith((ref) async => '127.0.0.1'),
      ],
      child: testApp(
        theme: ThemeData(
          brightness: Brightness.dark,
          fontFamily: 'Roboto',
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3FCDF5), brightness: Brightness.dark),
        ),
        home: const PilotScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

class _FixedControl extends ControlNotifier {
  _FixedControl(this.initial);

  final ControlState initial;

  @override
  ControlState build() => initial;
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('walking, robot ready', (tester) async {
    await _pump(tester, const ControlState(scheme: Scheme.walk), _telemetry(pb.State.STATE_NORMAL));
    await expectLater(find.byType(PilotScreen), matchesGoldenFile('goldens/walk.png'));
  });

  testWidgets('failsafe: sat down after signal loss', (tester) async {
    await _pump(
      tester,
      const ControlState(scheme: Scheme.walk),
      _telemetry(pb.State.STATE_SAFE_SIT, faults: 4 | 8),
    );
    await expectLater(find.byType(PilotScreen), matchesGoldenFile('goldens/safe_sit.png'));
  });

  testWidgets('first run tips', (tester) async {
    await _pump(tester, const ControlState(), _telemetry(pb.State.STATE_RELAXED), onboarded: false);
    await expectLater(find.byType(PilotScreen), matchesGoldenFile('goldens/onboarding.png'));
  });

  // The densest phone we drive with (Redmi Note 14: 450 dpi, 853 x 384 dp):
  // the top bar, the sticks and the side controls must not overlap.
  testWidgets('dense phone, relaxed with warnings', (tester) async {
    await _pump(
      tester,
      const ControlState(),
      _telemetry(pb.State.STATE_RELAXED, faults: 4 | 8 | 16 | 32 | 2048)..batteryVoltageV = 0,
      pixelRatio: 450 / 160,
    );
    await expectLater(find.byType(PilotScreen), matchesGoldenFile('goldens/dense_phone.png'));
  });

  testWidgets('front legs mode with gestures', (tester) async {
    await _pump(tester, const ControlState(scheme: Scheme.legs), _telemetry(pb.State.STATE_NORMAL));
    await expectLater(find.byType(PilotScreen), matchesGoldenFile('goldens/legs.png'));
  });
}
