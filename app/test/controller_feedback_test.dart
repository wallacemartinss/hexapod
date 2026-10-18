import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamepads/gamepads.dart';
import 'package:hexapod_app/core/control/control_state.dart';
import 'package:hexapod_app/core/input/controller_feedback.dart';
import 'package:hexapod_app/core/input/controller_platform.dart';
import 'package:hexapod_app/core/input/gamepad_interpreter.dart';
import 'package:hexapod_app/core/input/gamepad_service.dart';
import 'package:hexapod_app/core/link/robot_link.dart';
import 'package:hexapod_app/core/proto.dart' as pb;
import 'package:hexapod_app/core/providers.dart';

class FakePlatform implements ControllerPlatform {
  final lights = <int>[];
  @override
  Future<bool> setLight(int argb) async {
    lights.add(argb);
    return true;
  }

  @override
  Future<bool> openBluetoothSettings() async => true;
  @override
  Future<bool> hasRumble(String gamepadId) async => true;
  @override
  Future<void> rumble(String gamepadId, Rumble r) async {}
  @override
  Stream<MotionSample> motion() => const Stream.empty();
}

void main() {
  group('light bar', () {
    test('tells the state at a glance', () {
      int c(pb.State? s, {Scheme scheme = Scheme.walk, bool estop = false, bool connected = true}) =>
          lightColor(connected: connected, estop: estop, state: s, scheme: scheme);
      expect(c(pb.State.STATE_NORMAL), 0xFF00E060); // green: walking, all good
      expect(c(pb.State.STATE_NORMAL, scheme: Scheme.legs), 0xFFB000FF); // purple: paws
      expect(c(pb.State.STATE_SAFE_SIT), 0xFFFF8C00); // amber: failsafe
      expect(c(pb.State.STATE_TIPPED), 0xFFFF0000); // red: danger
      expect(c(pb.State.STATE_NORMAL, estop: true), 0xFFFF0000); // red: stopped
      expect(c(pb.State.STATE_RELAXED), 0xFF0050FF); // blue: no torque
      expect(c(pb.State.STATE_NORMAL, connected: false), 0xFF303030); // dim: no robot
    });
  });

  group('rumble', () {
    test('obstacle buzz grows as it gets closer, silent when far', () {
      expect(Rumble.obstacle(800), isNull);
      expect(Rumble.obstacle(0), isNull, reason: 'no reading');
      expect(Rumble.obstacle(150)!.low, greaterThan(Rumble.obstacle(400)!.low));
    });
  });

  group('tilt', () {
    test('relative to how the pad was held, clamped', () {
      final t = TiltTracker();
      t.accel(0, 0, 9.81);
      t.zero();
      expect(t.stick(), const Stick(0, 0));
      // Right side down by ~15 deg.
      for (var i = 0; i < 50; i++) {
        t.accel(9.81 * 0.2588, 0, 9.81 * 0.9659);
      }
      expect(t.stick().x, closeTo(15 / TiltTracker.fullScaleDeg, 0.02));
      // Far edge down a lot: pitch saturates, stick y negative (nose down).
      for (var i = 0; i < 50; i++) {
        t.accel(0, 9.81 * 0.8, 9.81 * 0.6);
      }
      expect(t.stick().y, -1);
    });
  });

  group('interpreter feedback', () {
    late ProviderContainer container;
    late GamepadInterpreter pad;
    final rumbles = <Rumble>[];

    setUp(() {
      rumbles.clear();
      container = ProviderContainer();
      pad = GamepadInterpreter(container.read(controlProvider.notifier), onRumble: rumbles.add);
    });
    tearDown(() => container.dispose());

    test('holding to stand ticks, then confirms', () {
      pad.onButton(GamepadButton.dpadUp, true);
      for (var i = 0; i < 20; i++) {
        pad.tick(const Duration(milliseconds: 50));
      }
      expect(rumbles.where((r) => identical(r, Rumble.tick)).length, 4);
      expect(rumbles.last, same(Rumble.confirm));
    });

    test('L1 in pose: tilting the pad tilts the body, release levels it', () {
      final control = container.read(controlProvider.notifier);
      control.stand();
      control.standDone();
      expect(container.read(controlProvider).scheme, Scheme.pose);
      pad.onMotion(const MotionSample(gyro: false, x: 0, y: 0, z: 9.81));
      pad.onButton(GamepadButton.leftBumper, true);
      for (var i = 0; i < 50; i++) {
        pad.onMotion(const MotionSample(gyro: false, x: 9.81 * 0.2588, y: 0, z: 9.81 * 0.9659));
      }
      expect(container.read(controlProvider).left.x, greaterThan(0.5));
      pad.onAxis(GamepadAxis.leftStickX, -1); // the left stick does not fight the tilt
      expect(container.read(controlProvider).left.x, greaterThan(0.5));
      pad.onButton(GamepadButton.leftBumper, false);
      expect(container.read(controlProvider).left, Stick.zero);
    });
  });

  test('service: light follows the robot and the STOP', () async {
    final fake = FakePlatform();
    final telemetry = StreamController<pb.Telemetry>.broadcast();
    final container = ProviderContainer(
      overrides: [
        controllerPlatformProvider.overrideWithValue(fake),
        linkStatusProvider.overrideWith((ref) => Stream.value(LinkStatus.connected)),
        telemetryProvider.overrideWith((ref) => telemetry.stream),
      ],
    );
    addTearDown(container.dispose);
    container.read(gamepadServiceProvider);
    container.listen(linkStatusProvider, (_, _) {});
    container.listen(telemetryProvider, (_, _) {});
    await Future<void>.delayed(Duration.zero);
    telemetry.add(pb.Telemetry()..state = pb.State.STATE_RELAXED);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(fake.lights.last, 0xFF0050FF);
    container.read(controlProvider.notifier).stop();
    await Future<void>.delayed(Duration.zero);
    expect(fake.lights.last, 0xFFFF0000);
    await telemetry.close();
  });
}
