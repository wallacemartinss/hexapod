// Body orientation from the BNO085 game rotation vector (gyro + accelerometer,
// no magnetometer: yaw drifts slowly but never jumps near motors and
// batteries). Pure logic: no Arduino.
#pragma once

namespace hexapod {
namespace sensors {

struct Quat {
  float w = 1, x = 0, y = 0, z = 0;
};

struct Orientation {
  Quat q;               // normalized, body frame
  float roll_deg = 0;   // + = right side down (as Command.body_roll)
  float pitch_deg = 0;  // + = nose down
  float yaw_deg = 0;    // + = turned left, -180..180
};

// From a sensor quaternion (any length) to body angles. The mounting
// offsets in config.h are subtracted from roll and pitch.
Orientation ToOrientation(Quat q);

}  // namespace sensors
}  // namespace hexapod
