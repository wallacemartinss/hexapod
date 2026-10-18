import '../proto.dart';
import 'control_state.dart';

/// Stick shaping, from the settings screen.
class StickShaping {
  const StickShaping({this.deadzone = 0.08, this.expo = 0.35, this.maxSpeed = 1.0});

  /// Deflection below this is zero (thumbs never rest exactly centered).
  final double deadzone;

  /// 0 = linear, 1 = cubic: fine control near the center, full range kept.
  final double expo;

  /// Scales walking speeds (0..1), for beginners or tight spaces.
  final double maxSpeed;

  double shape(double v) {
    final a = v.abs();
    if (a <= deadzone) return 0;
    final t = (a - deadzone) / (1 - deadzone);
    final curved = (1 - expo) * t + expo * t * t * t;
    return v.sign * curved;
  }
}

/// Turns the pilot's intent into the Command sent to hexd.
///
/// Axes (proto/hexapod/v1/command.proto): vx forward+, vy left+, yaw_rate
/// counter-clockwise+. Sticks: x right+, y up+. Firmware body pitch is
/// positive nose-down, so "look up" is a negative pitch.
class CommandMapper {
  const CommandMapper([this.shaping = const StickShaping()]);

  final StickShaping shaping;

  Command map(ControlState s) {
    final c = Command()
      ..bodyHeight = s.bodyHeight
      ..gait = s.gait
      ..estop = s.estop;
    final l = Stick(shaping.shape(s.left.x), shaping.shape(s.left.y)).clamped();
    final r = Stick(shaping.shape(s.right.x), shaping.shape(s.right.y)).clamped();

    if (s.standRequested) {
      c.mode = Mode.MODE_STAND;
      return c; // a clean STAND: no motion while the robot gets up
    }
    switch (s.scheme) {
      case Scheme.sit:
        c.mode = Mode.MODE_SIT;
      case Scheme.pose:
        c
          ..mode = Mode.MODE_STAND
          ..bodyRoll = l.x
          ..bodyPitch = -l.y
          ..bodyYaw = -r.x;
      case Scheme.walk:
        c
          ..mode = Mode.MODE_WALK
          ..vx = l.y * shaping.maxSpeed
          ..vy = -l.x * shaping.maxSpeed
          ..yawRate = -r.x * shaping.maxSpeed
          ..bodyPitch = -r.y; // right stick up: look up
      case Scheme.legs:
        // Vertical = lift the paw; horizontal outwards = reach forward.
        c
          ..mode = Mode.MODE_FRONT_LEGS
          ..frontLegs = (FrontLegs()
            ..leftLift = l.y
            ..leftReach = -l.x
            ..rightLift = r.y
            ..rightReach = r.x)
          ..gesture = s.gesture;
    }
    return c;
  }
}
