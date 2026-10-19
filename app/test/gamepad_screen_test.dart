import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'helpers/app.dart';
import 'package:hexapod_app/core/control/control_state.dart';
import 'package:hexapod_app/core/input/gamepad_interpreter.dart';
import 'package:hexapod_app/core/input/gamepad_service.dart';
import 'package:hexapod_app/core/link/robot_link.dart';
import 'package:hexapod_app/core/proto.dart' as pb;
import 'package:hexapod_app/core/providers.dart';
import 'package:hexapod_app/core/settings.dart';
import 'package:hexapod_app/features/pilot/pilot_screen.dart';
import 'package:hexapod_app/features/pilot/widgets/floating_joystick.dart';
import 'package:hexapod_app/features/settings/controller_sheet.dart';
import 'package:hexapod_app/features/video/video_view.dart';

class _StartAs extends ControlNotifier {
  @override
  ControlState build() {
    super.build();
    return const ControlState(scheme: Scheme.walk);
  }
}

List<Override> _overrides(Settings settings) => [
  commandLoopProvider.overrideWith((ref) {}),
  piStatusProvider.overrideWith((ref) => const Stream.empty()),
  // No gamepads plugin under test: the pad is whatever gamepadNameProvider says.
  gamepadServiceProvider.overrideWith((ref) => GamepadInterpreter(ref.read(controlProvider.notifier))),
  controllerPlatformProvider.overrideWith((ref) => null),
  videoViewProvider.overrideWith(
    (ref) =>
        (_) => const VideoPlaceholder(),
  ),
  linkStatusProvider.overrideWith((ref) => Stream.value(LinkStatus.connected)),
  telemetryProvider.overrideWith(
    (ref) => Stream.periodic(
      const Duration(milliseconds: 100),
      (_) => pb.Telemetry()
        ..state = pb.State.STATE_NORMAL
        ..batteryVoltageV = 11.6
        ..distancesMm.addAll([1300, 1300, 1300, 1300]),
    ),
  ),
  helloProvider.overrideWith((ref) => const Stream.empty()),
  controlProvider.overrideWith(_StartAs.new),
  settingsProvider.overrideWith(() => SettingsNotifier(settings)),
  robotAddressProvider.overrideWith((ref) async => '127.0.0.1'),
];

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  Settings settings = const Settings(onboarded: true),
}) async {
  tester.view.physicalSize = const Size(2400, 1080);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(overrides: _overrides(settings));
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: testApp(home: const PilotScreen()),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  return container;
}

void main() {
  testWidgets('a connected pad replaces the screen sticks; they come back when it leaves', (tester) async {
    final c = await _pump(tester);
    expect(find.byType(FloatingJoystick), findsNWidgets(2));

    c.read(gamepadNameProvider.notifier).set('DualSense Wireless Controller');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(FloatingJoystick), findsNothing);
    expect(find.text('PARAR'), findsOneWidget); // STOP stays on screen
    expect(find.text('Controle conectado'), findsOneWidget);

    c.read(gamepadNameProvider.notifier).set(null);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(FloatingJoystick), findsNWidgets(2));
    expect(find.text('Controle desconectado'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('the setting keeps the screen sticks with a pad', (tester) async {
    final c = await _pump(tester, settings: const Settings(onboarded: true, hideSticksWithPad: false));
    c.read(gamepadNameProvider.notifier).set('DualSense Wireless Controller');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(FloatingJoystick), findsNWidgets(2));
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('controller sheet: pairing steps without a pad, test button with one', (tester) async {
    final container = ProviderContainer(overrides: _overrides(const Settings(onboarded: true)));
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: testApp(home: const Scaffold(body: ControllerSheet())),
      ),
    );
    expect(find.text('Nenhum controle conectado'), findsOneWidget);
    expect(find.textContaining('PS + Create'), findsOneWidget); // steps open
    expect(find.text('Testar'), findsNothing);

    container.read(gamepadNameProvider.notifier).set('DualSense Wireless Controller');
    await tester.pump();
    expect(find.text('Conectado'), findsOneWidget);
    expect(find.text('Testar'), findsOneWidget);
  });
}
