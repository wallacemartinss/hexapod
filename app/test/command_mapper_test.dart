import 'package:flutter_test/flutter_test.dart';
import 'package:hexapod_app/core/control/command_mapper.dart';
import 'package:hexapod_app/core/control/control_state.dart';
import 'package:hexapod_app/core/proto.dart';

void main() {
  const linear = CommandMapper(StickShaping(deadzone: 0, expo: 0));

  group('stick shaping', () {
    const s = StickShaping(deadzone: 0.1, expo: 0.5);
    test('deadzone is zero', () {
      expect(s.shape(0.05), 0);
      expect(s.shape(-0.1), 0);
    });
    test('full deflection stays full, sign kept', () {
      expect(s.shape(1), closeTo(1, 1e-9));
      expect(s.shape(-1), closeTo(-1, 1e-9));
    });
    test('expo gives finer control near the center', () {
      expect(s.shape(0.4), lessThan(const StickShaping(deadzone: 0.1, expo: 0).shape(0.4)));
    });
  });

  group('walk', () {
    test('left stick moves, right turns and looks', () {
      final c = linear.map(
        const ControlState(
          scheme: Scheme.walk,
          left: Stick(0.5, 1), // forward and a bit right
          right: Stick(1, 1), // turn right, look up
        ),
      );
      expect(c.mode, Mode.MODE_WALK);
      expect(c.vx, greaterThan(0));
      expect(c.vy, lessThan(0), reason: 'right is negative vy');
      expect(c.yawRate, lessThan(0), reason: 'turning right is clockwise');
      expect(c.bodyPitch, lessThan(0), reason: 'looking up is nose-up (negative pitch)');
    });

    test('diagonal is clamped to the unit circle', () {
      final c = linear.map(const ControlState(scheme: Scheme.walk, left: Stick(1, 1)));
      expect(c.vx * c.vx + c.vy * c.vy, closeTo(1, 1e-6));
    });

    test('max speed setting scales motion', () {
      final c = const CommandMapper(
        StickShaping(deadzone: 0, expo: 0, maxSpeed: 0.4),
      ).map(const ControlState(scheme: Scheme.walk, left: Stick(0, 1)));
      expect(c.vx, closeTo(0.4, 1e-6));
    });
  });

  test('sit sends MODE_SIT and no motion', () {
    final c = linear.map(const ControlState(scheme: Scheme.sit, left: Stick(0, 1)));
    expect(c.mode, Mode.MODE_SIT);
    expect(c.vx, 0);
  });

  test('pose tilts and twists the body', () {
    final c = linear.map(const ControlState(scheme: Scheme.pose, left: Stick(1, 0), right: Stick(-1, 0)));
    expect(c.mode, Mode.MODE_STAND);
    expect(c.bodyRoll, closeTo(1, 1e-6));
    expect(c.bodyYaw, closeTo(1, 1e-6));
    expect(c.vx, 0);
  });

  test('legs: each stick drives one paw, outwards reaches forward', () {
    final c = linear.map(
      const ControlState(
        scheme: Scheme.legs,
        left: Stick(-1, 0), // outwards (left)
        right: Stick(0, 1), // up
        gesture: Gesture.GESTURE_WAVE,
      ),
    );
    expect(c.mode, Mode.MODE_FRONT_LEGS);
    expect(c.frontLegs.leftReach, closeTo(1, 1e-6));
    expect(c.frontLegs.rightLift, closeTo(1, 1e-6));
    expect(c.gesture, Gesture.GESTURE_WAVE);
  });

  test('stand request is a clean STAND, sticks ignored', () {
    final c = linear.map(const ControlState(scheme: Scheme.walk, left: Stick(0, 1), standRequested: true));
    expect(c.mode, Mode.MODE_STAND);
    expect(c.vx, 0);
  });

  test('estop is sent while latched, whatever the scheme', () {
    for (final scheme in Scheme.values) {
      expect(linear.map(ControlState(scheme: scheme, estop: true)).estop, isTrue);
    }
  });

  test('body height and gait pass through', () {
    final c = linear.map(const ControlState(scheme: Scheme.walk, bodyHeight: 0.8));
    expect(c.bodyHeight, closeTo(0.8, 1e-6));
    expect(c.gait, Gait.GAIT_TRIPOD);
  });
}
