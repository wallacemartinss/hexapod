#include "motion/controller.h"

#include <math.h>

#include "config.h"

namespace hexapod {
namespace motion {
namespace {

float Clamp(float v, float lo, float hi) {
  return v < lo ? lo : (v > hi ? hi : v);
}

float Step(float current, float target, float max_step) {
  return current + Clamp(target - current, -max_step, max_step);
}

float BodyHeightMm(float normalized) {
  return config::kBodyHeightMinMm +
         Clamp(normalized, 0.0f, 1.0f) *
             (config::kBodyHeightMaxMm - config::kBodyHeightMinMm);
}

Vec3 SitFoot(int leg) {
  const Vec3 p = LegToBody(leg, Vec3{config::kSitReachMm, 0.0f, 0.0f});
  return {p.x, p.y, -config::kSitHeightMm};
}

}  // namespace

JointAngles RateLimit(const JointAngles& current, const JointAngles& target,
                      float max_step_deg) {
  return {Step(current.coxa_deg, target.coxa_deg, max_step_deg),
          Step(current.femur_deg, target.femur_deg, max_step_deg),
          Step(current.tibia_deg, target.tibia_deg, max_step_deg)};
}

MotionController::MotionController() {
  Vec3 feet[kLegCount];
  for (int i = 0; i < kLegCount; ++i) feet[i] = SitFoot(i);
  SetTargetsFromFeet(feet);
  for (int i = 0; i < kLegCount; ++i) joints_[i] = targets_[i];
  gait_.Reset(BodyHeightMm(0.5f));
}

void MotionController::SetTargetsFromFeet(const Vec3 feet[kLegCount]) {
  ik_fail_mask_ = 0;
  for (int i = 0; i < kLegCount; ++i) {
    if (!SolveLeg(BodyToLeg(i, feet[i]), &targets_[i])) {
      ik_fail_mask_ |= static_cast<uint8_t>(1u << i);
    }
  }
}

void MotionController::Update(const MotionInput& in,
                              const safety::Output& failsafe, float dt_s) {
  if (in.mode != hexapod_v1_Mode_MODE_UNSPECIFIED) mode_ = in.mode;

  // Relaxed: no torque. Hold the angles; nothing would move them anyway.
  if (failsafe.posture == safety::Posture::kRelax) return;

  const float height = BodyHeightMm(in.body_height);
  const bool want_sit = failsafe.posture == safety::Posture::kSit ||
                        mode_ == hexapod_v1_Mode_MODE_SIT ||
                        mode_ == hexapod_v1_Mode_MODE_CALIBRATE;
  const bool want_legs =
      mode_ == hexapod_v1_Mode_MODE_FRONT_LEGS && !want_sit && !sitting_;
  Vec3 feet[kLegCount];

  // Front legs mode owns the feet from the first body shift until the body
  // is back, including on the way out to sitting. It starts from a still
  // stance: until the gait has settled, the branch below stops it.
  if (legs_.active() || (want_legs && gait_.idle())) {
    legs_.Update(want_legs, in.paws, in.gesture, settled_, height, dt_s, feet);
    if (legs_.active()) {
      Track(feet, dt_s);
      return;
    }
  }

  if (want_sit) {
    // Finish the steps in progress with all feet down, then lower the body.
    GaitCommand still;
    still.body_height_mm = sitting_ ? height : gait_.applied().body_height_mm;
    gait_.Update(still, dt_s);
    if (gait_.idle() || sitting_) {
      sitting_ = true;
      for (int i = 0; i < kLegCount; ++i) feet[i] = SitFoot(i);
    } else {
      for (int i = 0; i < kLegCount; ++i) feet[i] = gait_.foot(i);
    }
  } else {
    if (sitting_) {
      sitting_ = false;  // stand up: the joint limiter makes it gradual
      gait_.Reset(height);
    }
    GaitCommand command;
    command.body_height_mm = height;
    if (mode_ == hexapod_v1_Mode_MODE_WALK) {
      float vx = Clamp(in.vx, -1.0f, 1.0f) * failsafe.speed_scale;
      float vy = Clamp(in.vy, -1.0f, 1.0f) * failsafe.speed_scale;
      safety::ClampVelocity(failsafe.blocked_mask, &vx, &vy);
      command.vx_mm_s = vx * config::kMaxSpeedMmS;
      command.vy_mm_s = vy * config::kMaxSpeedMmS;
      command.yaw_rate_rad_s = Clamp(in.yaw_rate, -1.0f, 1.0f) *
                               failsafe.speed_scale * config::kMaxYawRateDegS *
                               kDegToRad;
    }
    gait_.Update(command, dt_s);
    const float roll =
        Clamp(in.body_roll, -1.0f, 1.0f) * config::kMaxBodyRollDeg;
    const float pitch =
        Clamp(in.body_pitch, -1.0f, 1.0f) * config::kMaxBodyPitchDeg;
    const float yaw = Clamp(in.body_yaw, -1.0f, 1.0f) * config::kMaxBodyYawDeg;
    for (int i = 0; i < kLegCount; ++i) {
      feet[i] = RotateIntoBody(gait_.foot(i), roll, pitch, yaw);
    }
  }

  Track(feet, dt_s);
}

void MotionController::Track(const Vec3 feet[kLegCount], float dt_s) {
  SetTargetsFromFeet(feet);
  const float max_step = config::kMaxJointSpeedDegS * dt_s;
  settled_ = true;
  for (int i = 0; i < kLegCount; ++i) {
    joints_[i] = RateLimit(joints_[i], targets_[i], max_step);
    const JointAngles& j = joints_[i];
    const JointAngles& t = targets_[i];
    if (fabsf(j.coxa_deg - t.coxa_deg) > config::kSettledDeg ||
        fabsf(j.femur_deg - t.femur_deg) > config::kSettledDeg ||
        fabsf(j.tibia_deg - t.tibia_deg) > config::kSettledDeg) {
      settled_ = false;
    }
  }
}

}  // namespace motion
}  // namespace hexapod
