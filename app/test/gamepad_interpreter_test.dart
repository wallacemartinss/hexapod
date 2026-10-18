import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamepads/gamepads.dart';
import 'package:hexapod_app/core/control/control_state.dart';
import 'package:hexapod_app/core/input/gamepad_interpreter.dart';
import 'package:hexapod_app/core/proto.dart';
import 'package:hexapod_app/core/providers.dart';

void main() {
  late ProviderContainer container;
  late GamepadInterpreter pad;
  ControlState state() => container.read(controlProvider);

  setUp(() {
    container = ProviderContainer();
    pad = GamepadInterpreter(container.read(controlProvider.notifier));
  });
  tearDown(() => container.dispose());

  void standUp() {
    pad.onButton(GamepadButton.dpadUp, true);
    for (var i = 0; i < 20; i++) {
      pad.tick(const Duration(milliseconds: 50));
    }
    pad.onButton(GamepadButton.dpadUp, false);
    container.read(controlProvider.notifier).standDone();
  }

  test('sticks do nothing while seated', () {
    pad.onAxis(GamepadAxis.leftStickY, 1);
    expect(state().left, Stick.zero);
  });

  test('d-pad up must be held to stand', () {
    pad.onButton(GamepadButton.dpadUp, true);
    pad.tick(const Duration(milliseconds: 300));
    pad.onButton(GamepadButton.dpadUp, false); // released early
    pad.tick(const Duration(milliseconds: 600));
    expect(state().standRequested, isFalse);
    standUp();
    expect(state().scheme, Scheme.pose);
  });

  test('mode buttons only once standing', () {
    pad.onButton(GamepadButton.a, true);
    expect(state().scheme, Scheme.sit);
    standUp();
    pad.onButton(GamepadButton.a, true);
    expect(state().scheme, Scheme.walk);
    pad.onButton(GamepadButton.y, true);
    expect(state().scheme, Scheme.legs);
  });

  test('sticks drive like the screen sticks', () {
    standUp();
    pad.onButton(GamepadButton.a, true);
    pad.onAxis(GamepadAxis.leftStickY, 0.8);
    pad.onAxis(GamepadAxis.rightStickX, -0.5);
    expect(state().left.y, closeTo(0.8, 1e-9));
    expect(state().right.x, closeTo(-0.5, 1e-9));
  });

  test('circle stops at once and latches', () {
    standUp();
    pad.onButton(GamepadButton.a, true);
    pad.onAxis(GamepadAxis.leftStickY, 1);
    pad.onButton(GamepadButton.b, true);
    expect(state().estop, isTrue);
    expect(state().left, Stick.zero);
    pad.onAxis(GamepadAxis.leftStickY, 1); // ignored while stopped
    expect(state().left, Stick.zero);
  });

  test('bluetooth drop releases the sticks', () {
    standUp();
    pad.onButton(GamepadButton.a, true);
    pad.onAxis(GamepadAxis.leftStickY, 1);
    pad.disconnected();
    expect(state().left, Stick.zero);
  });

  test('triggers move the body height', () {
    standUp();
    final before = state().bodyHeight;
    pad.onAxis(GamepadAxis.rightTrigger, 1);
    for (var i = 0; i < 10; i++) {
      pad.tick(const Duration(milliseconds: 50));
    }
    expect(state().bodyHeight, greaterThan(before + 0.2));
    pad.onAxis(GamepadAxis.rightTrigger, 0);
    pad.onAxis(GamepadAxis.leftTrigger, 1);
    for (var i = 0; i < 40; i++) {
      pad.tick(const Duration(milliseconds: 50));
    }
    expect(state().bodyHeight, 0);
  });

  test('bumpers play gestures in legs mode only', () {
    standUp();
    pad.onButton(GamepadButton.rightBumper, true);
    expect(state().gesture, Gesture.GESTURE_UNSPECIFIED);
    pad.onButton(GamepadButton.y, true);
    pad.onButton(GamepadButton.rightBumper, true);
    expect(state().gesture, Gesture.GESTURE_WAVE);
  });
}
