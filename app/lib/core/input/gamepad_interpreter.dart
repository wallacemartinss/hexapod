import 'package:gamepads/gamepads.dart';

import '../control/control_state.dart';
import '../proto.dart';
import '../providers.dart';

/// Turns gamepad input (PS5 DualSense or any standard pad) into the same
/// pilot actions as the touch screen, with the same safety rules:
///
/// | Input              | Action                                   |
/// |--------------------|------------------------------------------|
/// | sticks             | as the on-screen sticks                  |
/// | ○ (b)              | STOP                                     |
/// | d-pad up, held     | stand up (hold, like the screen button)  |
/// | d-pad down         | sit                                      |
/// | × / □ / △          | walk / pose / legs (only once standing)  |
/// | L2 / R2            | body down / up, proportional             |
/// | L1 / R1 / R3       | guard / wave / strike (legs mode)        |
///
/// Pure logic: the plugin glue feeds it (see gamepadServiceProvider).
class GamepadInterpreter {
  GamepadInterpreter(this.control, {this.standHold = const Duration(milliseconds: 700)});

  final ControlNotifier control;
  final Duration standHold;

  /// Body height change at full trigger, per second (0..1 scale).
  static const heightRate = 0.5;

  double _lx = 0, _ly = 0, _rx = 0, _ry = 0;
  double _lt = 0, _rt = 0;
  Duration? _standHeld;

  /// Progress of the d-pad-up hold, 0..1 (for on-screen feedback).
  double get standProgress {
    final held = _standHeld;
    if (held == null) return 0;
    return (held.inMicroseconds / standHold.inMicroseconds).clamp(0.0, 1.0);
  }

  void onAxis(GamepadAxis axis, double value) {
    switch (axis) {
      case GamepadAxis.leftStickX:
        _lx = value;
      case GamepadAxis.leftStickY:
        _ly = value;
      case GamepadAxis.rightStickX:
        _rx = value;
      case GamepadAxis.rightStickY:
        _ry = value;
      case GamepadAxis.leftTrigger:
        _lt = value;
        return;
      case GamepadAxis.rightTrigger:
        _rt = value;
        return;
    }
    if (control.current.scheme == Scheme.sit) return;
    control.setSticks(left: Stick(_lx, _ly).clamped(), right: Stick(_rx, _ry).clamped());
  }

  void onButton(GamepadButton button, bool pressed) {
    if (button == GamepadButton.dpadUp) {
      _standHeld = pressed ? Duration.zero : null;
      return;
    }
    if (!pressed) return;
    final state = control.current;
    final up = state.scheme != Scheme.sit; // walk/pose/legs need a standing robot
    switch (button) {
      case GamepadButton.b:
        control.stop();
      case GamepadButton.dpadDown:
        control.sit();
      case GamepadButton.a when up:
        control.setScheme(Scheme.walk);
      case GamepadButton.x when up:
        control.setScheme(Scheme.pose);
      case GamepadButton.y when up:
        control.setScheme(Scheme.legs);
      case GamepadButton.leftBumper when state.scheme == Scheme.legs:
        control.gesture(Gesture.GESTURE_GUARD);
      case GamepadButton.rightBumper when state.scheme == Scheme.legs:
        control.gesture(Gesture.GESTURE_WAVE);
      case GamepadButton.rightStick when state.scheme == Scheme.legs:
        control.gesture(Gesture.GESTURE_STRIKE);
      default:
        break;
    }
  }

  /// Call periodically (the command rate is fine).
  void tick(Duration dt) {
    final held = _standHeld;
    if (held != null) {
      final next = held + dt;
      if (next >= standHold) {
        _standHeld = null; // fires once per press
        control.stand();
      } else {
        _standHeld = next;
      }
    }
    final dh = (_rt - _lt) * heightRate * dt.inMicroseconds / 1e6;
    if (dh != 0) control.setBodyHeight(control.current.bodyHeight + dh);
  }

  /// Bluetooth dropped: never leave a stick deflected.
  void disconnected() {
    _lx = _ly = _rx = _ry = _lt = _rt = 0;
    _standHeld = null;
    control.releaseSticks();
  }
}
