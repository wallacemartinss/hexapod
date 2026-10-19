import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'helpers/app.dart';
import 'package:hexapod_app/core/input/gamepad_interpreter.dart';
import 'package:hexapod_app/core/input/gamepad_service.dart';
import 'package:hexapod_app/core/link/robot_link.dart';
import 'package:hexapod_app/core/proto.dart' as pb;
import 'package:hexapod_app/core/providers.dart';
import 'package:hexapod_app/core/settings.dart';
import 'package:hexapod_app/features/pilot/pilot_screen.dart';
import 'package:hexapod_app/features/video/video_view.dart';

Future<void> _pump(WidgetTester tester, pb.Telemetry t) async {
  tester.view.physicalSize = const Size(2400, 1080);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
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
        telemetryProvider.overrideWith((ref) => Stream.periodic(const Duration(milliseconds: 100), (_) => t)),
        helloProvider.overrideWith((ref) => const Stream.empty()),
        settingsProvider.overrideWith(() => SettingsNotifier(const Settings(onboarded: true))),
        robotAddressProvider.overrideWith((ref) async => '127.0.0.1'),
      ],
      child: testApp(home: const PilotScreen()),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('a gas alarm shows a banner on the pilot screen', (tester) async {
    await _pump(
      tester,
      pb.Telemetry()
        ..state = pb.State.STATE_NORMAL
        ..gasAlarm = true
        ..gasLevelPct = 55,
    );
    expect(find.textContaining('detectou gás ou fumaça'), findsOneWidget);
  });

  testWidgets('no banner while the MQ-2 reports as not fitted', (tester) async {
    await _pump(
      tester,
      pb.Telemetry()
        ..state = pb.State.STATE_NORMAL
        ..gasAlarm =
            true // garbage from a sensor marked absent
        ..faultFlags = 2048,
    );
    expect(find.textContaining('detectou gás ou fumaça'), findsNothing);
  });
}
