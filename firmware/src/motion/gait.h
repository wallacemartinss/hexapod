// Tripod gait: legs {0, 2, 4} and {1, 3, 5} alternate, so exactly one group
// swings while the other three feet stay on the ground.
//
// Stance feet are integrated from the body velocity (they stay fixed on the
// ground while the body moves); swing feet arc from lift-off to a touchdown
// point ahead of the neutral position. With zero velocity the gait finishes
// the steps in progress, lands every foot at neutral and holds still.
//
// Every foot stays within kMaxHalfStrideMm of its neutral spot: speed is capped
// so a stance fits in the stride (minus a margin), speeding up is
// acceleration-limited so the margin absorbs it, and as a last resort a stance
// foot stops at the limit.
#pragma once

#include "motion/ik.h"
#include "motion/vec3.h"

namespace hexapod {
namespace motion {

struct GaitCommand {
  float vx_mm_s = 0.0f;  // body velocity, body frame
  float vy_mm_s = 0.0f;
  float yaw_rate_rad_s = 0.0f;
  float body_height_mm = 0.0f;
};

class TripodGait {
 public:
  // Feet planted at neutral for `body_height_mm`, gait idle.
  void Reset(float body_height_mm);

  // Advances the gait by `dt_s` (must be shorter than half a cycle).
  void Update(const GaitCommand& command, float dt_s);

  const Vec3& foot(int leg) const { return feet_[leg]; }  // body frame
  bool swinging(int leg) const { return swing_[leg]; }
  bool idle() const { return idle_; }
  // Velocity actually used after the stride limit (body frame).
  const GaitCommand& applied() const { return applied_; }

  static int Group(int leg) {
    return (leg == 0 || leg == 2 || leg == 4) ? 0 : 1;
  }
  static Vec3 Neutral(int leg, float body_height_mm);

 private:
  GaitCommand Limit(const GaitCommand& command) const;
  GaitCommand Ramp(const GaitCommand& target, float dt_s) const;
  Vec3 Touchdown(int leg, const GaitCommand& c) const;

  float phase_ = 0.0f;  // 0..1: group 0 swings in [0, 0.5), group 1 after
  bool idle_ = true;
  int settle_boundaries_ = 0;  // half-cycles left before idling
  Vec3 feet_[kLegCount];
  Vec3 liftoff_[kLegCount];
  float swing_start_[kLegCount] = {};  // phase at lift-off
  bool swing_[kLegCount] = {};
  GaitCommand applied_;
};

}  // namespace motion
}  // namespace hexapod
