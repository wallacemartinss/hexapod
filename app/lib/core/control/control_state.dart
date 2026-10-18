import 'dart:math' as math;

import '../proto.dart';

/// A stick deflection, both axes in -1..1 (x right, y up).
class Stick {
  const Stick(this.x, this.y);

  static const zero = Stick(0, 0);

  final double x;
  final double y;

  /// Clamps to the unit circle (a thumb can overshoot the ring).
  Stick clamped() {
    final m = math.sqrt(x * x + y * y);
    return m <= 1 ? this : Stick(x / m, y / m);
  }

  @override
  bool operator ==(Object other) => other is Stick && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

/// What the sticks drive. The robot mode follows from it.
enum Scheme {
  /// Seated (MODE_SIT). Sticks do nothing.
  sit,

  /// Standing still (MODE_STAND). Sticks tilt and turn the body.
  pose,

  /// Walking (MODE_WALK). Left moves, right turns and looks up/down.
  walk,

  /// Front legs raised (MODE_FRONT_LEGS). Each stick drives one paw.
  legs,
}

/// Everything the pilot asks for, independent of the input device (touch
/// joysticks or a gamepad both write here). [CommandMapper] turns it into the
/// Command sent at 20 Hz.
class ControlState {
  const ControlState({
    this.scheme = Scheme.sit,
    this.left = Stick.zero,
    this.right = Stick.zero,
    this.bodyHeight = 0.5,
    this.gait = Gait.GAIT_TRIPOD,
    this.gesture = Gesture.GESTURE_UNSPECIFIED,
    this.estop = false,
    this.standRequested = false,
  });

  final Scheme scheme;
  final Stick left;
  final Stick right;

  /// 0 = lowest allowed, 1 = highest (firmware maps it to millimeters).
  final double bodyHeight;
  final Gait gait;

  /// A gesture pulse; returns to UNSPECIFIED by itself (see ControlNotifier).
  final Gesture gesture;

  /// Latched by the STOP button; only a deliberate stand clears it.
  final bool estop;

  /// Set by the hold-to-stand button: sends MODE_STAND, which is also the
  /// only way to leave a failsafe state.
  final bool standRequested;

  ControlState copyWith({
    Scheme? scheme,
    Stick? left,
    Stick? right,
    double? bodyHeight,
    Gait? gait,
    Gesture? gesture,
    bool? estop,
    bool? standRequested,
  }) => ControlState(
    scheme: scheme ?? this.scheme,
    left: left ?? this.left,
    right: right ?? this.right,
    bodyHeight: bodyHeight ?? this.bodyHeight,
    gait: gait ?? this.gait,
    gesture: gesture ?? this.gesture,
    estop: estop ?? this.estop,
    standRequested: standRequested ?? this.standRequested,
  );
}
