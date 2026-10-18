// Turns the pilot command and the failsafe output into 18 joint angles,
// every 50 Hz cycle. Joints never jump: each one moves towards its target at
// most kMaxJointSpeedDegS.
#pragma once

#include <stdint.h>

#include "hexapod/v1/common.pb.h"
#include "motion/gait.h"
#include "motion/ik.h"
#include "safety/failsafe.h"

namespace hexapod {
namespace motion {

// Normalized pilot command (see proto/hexapod/v1/command.proto).
struct MotionInput {
  hexapod_v1_Mode mode = hexapod_v1_Mode_MODE_UNSPECIFIED;  // keep current
  float vx = 0.0f;                                          // -1..1
  float vy = 0.0f;
  float yaw_rate = 0.0f;
  float body_height = 0.5f;  // 0..1
  float body_roll = 0.0f;    // -1..1
  float body_pitch = 0.0f;
  float body_yaw = 0.0f;
};

class MotionController {
 public:
  // Starts seated, at the sit pose.
  MotionController();

  void Update(const MotionInput& input, const safety::Output& failsafe,
              float dt_s);

  const JointAngles& joints(int leg) const { return joints_[leg]; }
  hexapod_v1_Mode mode() const { return mode_; }
  bool sitting() const { return sitting_; }
  // Bit i: leg i had no IK solution this cycle and kept its last target.
  uint8_t ik_fail_mask() const { return ik_fail_mask_; }

 private:
  void SetTargetsFromFeet(const Vec3 feet[kLegCount]);

  hexapod_v1_Mode mode_ = hexapod_v1_Mode_MODE_SIT;
  bool sitting_ = true;
  TripodGait gait_;
  JointAngles targets_[kLegCount];
  JointAngles joints_[kLegCount];
  uint8_t ik_fail_mask_ = 0;
};

// Moves `current` towards `target` by at most `max_step` per joint.
JointAngles RateLimit(const JointAngles& current, const JointAngles& target,
                      float max_step_deg);

}  // namespace motion
}  // namespace hexapod
