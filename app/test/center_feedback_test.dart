import 'package:flutter/material.dart';
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

class _StartAs extends ControlNotifier {
  _StartAs(this.initial);

  final ControlState initial;

  @override
  ControlState build() {
    super.build();
    return initial;
  }
}

Future<void> _pump(WidgetTester tester, ControlState control, pb.State state) async {
  tester.view.physicalSize = const Size(2400, 1080);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  final telemetry = pb.Telemetry()
    ..state = state
    ..batteryVoltageV = 11.6
    ..distancesMm.addAll([1300, 1300, 1300, 1300]);
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
        controlProvider.overrideWith(() => _StartAs(control)),
        settingsProvider.overrideWith(() => SettingsNotifier(const Settings(onboarded: true))),
        robotAddressProvider.overrideWith((ref) async => '127.0.0.1'),
      ],
      child: testApp(home: const PilotScreen()),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('holding LEVANTAR shows the progress mid-screen, then "Levantando…"', (tester) async {
    await _pump(tester, const ControlState(), pb.State.STATE_SAFE_SIT);
    expect(find.text('Continue segurando'), findsNothing);

    final finger = await tester.startGesture(tester.getCenter(find.text('Levantar')));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Continue segurando'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 500)); // past the 0.7 s hold
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Levantando…'), findsOneWidget);
    await finger.up();
  });

  testWidgets('releasing early stands nothing up', (tester) async {
    await _pump(tester, const ControlState(), pb.State.STATE_SAFE_SIT);
    final finger = await tester.startGesture(tester.getCenter(find.text('Levantar')));
    await tester.pump(const Duration(milliseconds: 300));
    await finger.up();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Continue segurando'), findsNothing);
    expect(find.text('Levantando…'), findsNothing);
  });

  testWidgets('a gesture shows which one was sent, then goes away', (tester) async {
    await _pump(tester, const ControlState(scheme: Scheme.legs), pb.State.STATE_NORMAL);
    expect(find.text('Golpe'), findsOneWidget); // the button only

    await tester.tap(find.text('Golpe'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Golpe'), findsNWidgets(2)); // button + mid-screen card

    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Golpe'), findsOneWidget);
  });
}
