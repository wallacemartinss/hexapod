#include "sensors/orientation.h"

#include <math.h>

#include "config.h"

namespace hexapod {
namespace sensors {
namespace {

constexpr float kRadToDeg = 57.2957795f;

}  // namespace

Orientation ToOrientation(Quat q) {
  Orientation o;
  const float n = sqrtf(q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z);
  if (n < 1e-6f) return o;  // no data yet: level
  q.w /= n;
  q.x /= n;
  q.y /= n;
  q.z /= n;
  o.q = q;
  // Z-Y-X (yaw, pitch, roll) with x forward, y left, z up.
  o.roll_deg =
      atan2f(2 * (q.w * q.x + q.y * q.z), 1 - 2 * (q.x * q.x + q.y * q.y)) *
      kRadToDeg;
  const float s = 2 * (q.w * q.y - q.z * q.x);
  o.pitch_deg = asinf(s > 1 ? 1 : (s < -1 ? -1 : s)) * kRadToDeg;
  o.yaw_deg =
      atan2f(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z)) *
      kRadToDeg;
  o.roll_deg -= config::kImuRollOffsetDeg;
  o.pitch_deg -= config::kImuPitchOffsetDeg;
  return o;
}

float ToHeading(Quat q) {
  // Yaw is counter-clockwise, a heading clockwise.
  float h = config::kImuNorthYawDeg - ToOrientation(q).yaw_deg;
  h = fmodf(h, 360.0f);
  if (h < 0) h += 360.0f;
  return h >= 360.0f ? 0.0f : h;  // -1e-6 + 360 rounds to 360
}

}  // namespace sensors
}  // namespace hexapod
