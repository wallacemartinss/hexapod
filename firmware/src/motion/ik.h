// Leg kinematics (3 DOF: coxa yaw, femur pitch, tibia pitch).
// Frames and angle conventions: cad/README.md.
#pragma once

#include "motion/vec3.h"

namespace hexapod {
namespace motion {

constexpr int kLegCount = 6;

struct JointAngles {
  float coxa_deg = 0.0f;
  float femur_deg = 0.0f;
  float tibia_deg = 0.0f;
};

// Foot position (leg frame) for the given joint angles.
Vec3 ForwardLeg(const JointAngles& angles);

// Joint angles that put the foot at `foot` (leg frame), knee-up solution.
// Returns false, leaving `out` untouched, if the point is out of reach or the
// solution violates the joint limits in config.h.
bool SolveLeg(const Vec3& foot, JointAngles* out);

bool WithinLimits(const JointAngles& angles);

// Body frame <-> frame of leg `leg` (0..5).
Vec3 BodyToLeg(int leg, const Vec3& p);
Vec3 LegToBody(int leg, const Vec3& p);

// Expresses a world-fixed point in a body rotated by roll, pitch, yaw (deg),
// all about the body origin.
Vec3 RotateIntoBody(const Vec3& p, float roll_deg, float pitch_deg,
                    float yaw_deg);

}  // namespace motion
}  // namespace hexapod
