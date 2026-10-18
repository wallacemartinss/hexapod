#include "motion/ik.h"

#include "config.h"

namespace hexapod {
namespace motion {

Vec3 ForwardLeg(const JointAngles& a) {
  const float t1 = a.coxa_deg * kDegToRad;
  const float t2 = a.femur_deg * kDegToRad;
  const float t23 = (a.femur_deg + a.tibia_deg) * kDegToRad;
  const float r = config::kCoxaMm + config::kFemurMm * cosf(t2) +
                  config::kTibiaMm * cosf(t23);
  const float z = config::kFemurMm * sinf(t2) + config::kTibiaMm * sinf(t23);
  return {r * cosf(t1), r * sinf(t1), z};
}

bool SolveLeg(const Vec3& foot, JointAngles* out) {
  const float l2 = config::kFemurMm;
  const float l3 = config::kTibiaMm;
  const float r = NormXY(foot) - config::kCoxaMm;  // femur axis -> foot, flat
  const float d2 = r * r + foot.z * foot.z;
  const float c3 = (d2 - l2 * l2 - l3 * l3) / (2.0f * l2 * l3);
  if (c3 < -1.0f || c3 > 1.0f) return false;

  const float t3 = -acosf(c3);  // knee up: the tibia folds downwards
  const float t2 =
      atan2f(foot.z, r) + atan2f(l3 * sinf(-t3), l2 + l3 * cosf(t3));
  JointAngles a;
  a.coxa_deg = atan2f(foot.y, foot.x) * kRadToDeg;
  a.femur_deg = t2 * kRadToDeg;
  a.tibia_deg = t3 * kRadToDeg;
  if (!WithinLimits(a)) return false;
  *out = a;
  return true;
}

bool WithinLimits(const JointAngles& a) {
  return a.coxa_deg >= config::kCoxaMinDeg &&
         a.coxa_deg <= config::kCoxaMaxDeg &&
         a.femur_deg >= config::kFemurMinDeg &&
         a.femur_deg <= config::kFemurMaxDeg &&
         a.tibia_deg >= config::kTibiaMinDeg &&
         a.tibia_deg <= config::kTibiaMaxDeg;
}

Vec3 BodyToLeg(int leg, const Vec3& p) {
  const config::LegMount& m = config::kLegMounts[leg];
  const float a = m.angle_deg * kDegToRad;
  const float dx = p.x - m.x_mm;
  const float dy = p.y - m.y_mm;
  return {dx * cosf(a) + dy * sinf(a), -dx * sinf(a) + dy * cosf(a), p.z};
}

Vec3 LegToBody(int leg, const Vec3& p) {
  const config::LegMount& m = config::kLegMounts[leg];
  const float a = m.angle_deg * kDegToRad;
  return {m.x_mm + p.x * cosf(a) - p.y * sinf(a),
          m.y_mm + p.x * sinf(a) + p.y * cosf(a), p.z};
}

Vec3 RotateIntoBody(const Vec3& p, float roll_deg, float pitch_deg,
                    float yaw_deg) {
  // Body orientation R = Rz(yaw) * Ry(pitch) * Rx(roll); returns R^T * p.
  const float cr = cosf(roll_deg * kDegToRad), sr = sinf(roll_deg * kDegToRad);
  const float cp = cosf(pitch_deg * kDegToRad),
              sp = sinf(pitch_deg * kDegToRad);
  const float cy = cosf(yaw_deg * kDegToRad), sy = sinf(yaw_deg * kDegToRad);
  // Rz^T
  const Vec3 a = {cy * p.x + sy * p.y, -sy * p.x + cy * p.y, p.z};
  // Ry^T
  const Vec3 b = {cp * a.x - sp * a.z, a.y, sp * a.x + cp * a.z};
  // Rx^T
  return {b.x, cr * b.y + sr * b.z, -sr * b.y + cr * b.z};
}

}  // namespace motion
}  // namespace hexapod
