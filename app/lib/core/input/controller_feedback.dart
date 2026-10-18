import 'dart:math' as math;

import '../control/control_state.dart';
import '../proto.dart' as pb;

/// One vibration: two motors (low = heavy, high = light) for a duration,
/// repeated [times] with [gap] in between.
class Rumble {
  const Rumble(this.low, this.high, this.duration, {this.times = 1, this.gap = Duration.zero});

  final double low;
  final double high;
  final Duration duration;
  final int times;
  final Duration gap;

  /// STOP pressed: one heavy jolt.
  static const stop = Rumble(1, 1, Duration(milliseconds: 300));

  /// The failsafe acted (signal loss, tipped, battery...): two strong pulses.
  static const alarm = Rumble(
    0.9,
    0.6,
    Duration(milliseconds: 180),
    times: 2,
    gap: Duration(milliseconds: 120),
  );

  /// The app lost the robot: one long pulse.
  static const linkLost = Rumble(0.7, 0.2, Duration(milliseconds: 600));

  /// Hold-to-stand progress tick and its confirmation.
  static const tick = Rumble(0, 0.35, Duration(milliseconds: 40));
  static const confirm = Rumble(0.5, 0.8, Duration(milliseconds: 150));

  /// "Which controller is it?": the Test button in the controller sheet, and
  /// a newly connected pad.
  static const hello = Rumble(
    0.6,
    0.9,
    Duration(milliseconds: 180),
    times: 2,
    gap: Duration(milliseconds: 140),
  );

  /// A gesture started.
  static const tap = Rumble(0.2, 0.5, Duration(milliseconds: 80));

  /// Obstacle ahead while walking: a buzz that grows as it gets closer, or
  /// null when far (beyond [_obstacleMm]).
  static Rumble? obstacle(int frontMm) {
    if (frontMm <= 0 || frontMm >= _obstacleMm) return null;
    final k = 1 - frontMm / _obstacleMm;
    return Rumble(0.15 + 0.5 * k, 0.1 + 0.3 * k, const Duration(milliseconds: 250));
  }

  static const _obstacleMm = 450;
}

/// States worth an alarm rumble when they start.
const alarmStates = {
  pb.State.STATE_STOPPING,
  pb.State.STATE_SAFE_SIT,
  pb.State.STATE_TIPPED,
  pb.State.STATE_LOW_BATTERY,
  pb.State.STATE_ESTOP,
};

/// Light bar color (ARGB) for what the robot is doing, so the pilot can tell
/// at a glance without looking at the phone.
int lightColor({required bool connected, required bool estop, pb.State? state, required Scheme scheme}) {
  const white = 0xFF303030, red = 0xFFFF0000, amber = 0xFFFF8C00;
  const blue = 0xFF0050FF, green = 0xFF00E060, purple = 0xFFB000FF, cyan = 0xFF00C8FF;
  if (!connected || state == null) return white;
  if (estop || state == pb.State.STATE_ESTOP) return red;
  return switch (state) {
    pb.State.STATE_TIPPED || pb.State.STATE_LOW_BATTERY => red,
    pb.State.STATE_STOPPING || pb.State.STATE_SAFE_SIT || pb.State.STATE_BLOCKED => amber,
    pb.State.STATE_RELAXED => blue,
    _ => switch (scheme) {
      Scheme.legs => purple,
      Scheme.pose => cyan,
      Scheme.sit => blue,
      Scheme.walk => green,
    },
  };
}

/// Tilt control: the controller's gravity vector becomes body roll/pitch,
/// relative to how it was held when tilt control started.
///
/// TODO(hardware): confirm the DualSense sensor axes on the phone (assumed:
/// x right, y away from the player, z up with the pad lying flat).
class TiltTracker {
  /// Controller tilt that maps to full body roll/pitch.
  static const fullScaleDeg = 25.0;

  double _gx = 0, _gy = 0, _gz = 9.81;
  double _roll0 = 0, _pitch0 = 0;
  bool _hasSample = false;

  /// Accelerometer sample (m/s²); low-pass filtered to keep only gravity.
  void accel(double x, double y, double z) {
    const a = 0.2;
    if (!_hasSample) {
      _gx = x;
      _gy = y;
      _gz = z;
      _hasSample = true;
      return;
    }
    _gx += a * (x - _gx);
    _gy += a * (y - _gy);
    _gz += a * (z - _gz);
  }

  double get rollDeg => math.atan2(_gx, _gz) * 180 / math.pi; // right side down: +
  double get pitchDeg => math.atan2(_gy, _gz) * 180 / math.pi; // far edge down: +

  /// The current hold becomes "level".
  void zero() {
    _roll0 = rollDeg;
    _pitch0 = pitchDeg;
  }

  /// Stick for the pose scheme (left stick: x = roll, y = -pitch; see
  /// CommandMapper), clamped to the unit range.
  Stick stick() {
    double norm(double deg) => (deg / fullScaleDeg).clamp(-1.0, 1.0);
    return Stick(norm(rollDeg - _roll0), -norm(pitchDeg - _pitch0));
  }
}
