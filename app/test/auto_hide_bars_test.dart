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

class _FixedControl extends ControlNotifier {
  _FixedControl(this.initial);

  final ControlState initial;

  @override
  ControlState build() => initial;
}

Future<void> _pump(
  WidgetTester tester,
  pb.State state, {
  Settings settings = const Settings(onboarded: true),
  Scheme scheme = Scheme.walk,
}) async {
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
        controlProvider.overrideWith(() => _FixedControl(ControlState(scheme: scheme))),
        settingsProvider.overrideWith(() => SettingsNotifier(settings)),
        robotAddressProvider.overrideWith((ref) async => '127.0.0.1'),
      ],
      child: testApp(home: const PilotScreen()),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

/// Opacity of the bar that holds [label].
double _opacity(WidgetTester tester, String label) => tester
    .widget<AnimatedOpacity>(
      find.ancestor(of: find.text(label), matching: find.byType(AnimatedOpacity)).first,
    )
    .opacity;

Future<void> _wait(WidgetTester tester, Duration d) async {
  for (var t = Duration.zero; t < d; t += const Duration(milliseconds: 250)) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  testWidgets('mode bar and height slider hide while walking; a tap brings them back', (tester) async {
    await _pump(tester, pb.State.STATE_NORMAL);
    expect(_opacity(tester, 'Andar'), 1);
    expect(_opacity(tester, '50%'), 1);

    await _wait(tester, const Duration(seconds: 6));
    expect(_opacity(tester, 'Andar'), 0);
    expect(_opacity(tester, '50%'), 0);
    expect(find.text('PARAR'), findsOneWidget); // STOP never hides
    expect(find.text('Conectado'), findsOneWidget); // nor the status bar

    await tester.tapAt(const Offset(450, 200));
    await tester.pump();
    expect(_opacity(tester, 'Andar'), 1);
  });

  testWidgets('a drag (stick) does not bring them back', (tester) async {
    await _pump(tester, pb.State.STATE_NORMAL);
    await _wait(tester, const Duration(seconds: 6));
    await tester.dragFrom(const Offset(250, 250), const Offset(60, -40));
    await tester.pump();
    expect(_opacity(tester, 'Andar'), 0);
  });

  testWidgets('they stay while the robot is not up and moving', (tester) async {
    await _pump(tester, pb.State.STATE_SAFE_SIT);
    await _wait(tester, const Duration(seconds: 6));
    expect(_opacity(tester, 'Levantar'), 1);
  });

  testWidgets('the setting turns it off', (tester) async {
    await _pump(
      tester,
      pb.State.STATE_NORMAL,
      settings: const Settings(onboarded: true, autoHideBars: false),
    );
    await _wait(tester, const Duration(seconds: 6));
    expect(_opacity(tester, 'Andar'), 1);
  });

  testWidgets('seated (the ESP32 still reports NORMAL) keeps them on screen', (tester) async {
    await _pump(tester, pb.State.STATE_NORMAL, scheme: Scheme.sit);
    await _wait(tester, const Duration(seconds: 6));
    expect(_opacity(tester, 'Levantar'), 1);
  });
}
