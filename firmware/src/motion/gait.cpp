#include "motion/gait.h"

#include "config.h"

namespace hexapod {
namespace motion {
namespace {

constexpr float kPi = 3.14159265358979f;
constexpr float kStanceS = config::kGaitPeriodS / 2.0f;  // s per stance
// Part of the half stride kept free for speed changes during a stance (mm).
constexpr float kStrideMarginMm = 8.0f;
// Fastest planar foot speed whose stance fits in the stride minus the margin.
constexpr float kMaxFootSpeedMmS =
    2.0f * (config::kMaxHalfStrideMm - kStrideMarginMm) / kStanceS;
// Speeding up by at most this over a whole stance overshoots by <= the margin.
constexpr float kMaxFootAccelMmS2 =
    2.0f * kStrideMarginMm / (kStanceS * kStanceS);
constexpr float kMovingSpeedMmS = 1.0f;  // below this the body is still
constexpr float kMovingYawRadS = 0.005f;

// Planar velocity of a ground point at `p` as seen from the moving body.
Vec3 GroundVelocity(const GaitCommand& c, const Vec3& p) {
  return {-(c.vx_mm_s - c.yaw_rate_rad_s * p.y),
          -(c.vy_mm_s + c.yaw_rate_rad_s * p.x), 0.0f};
}

// Fastest planar foot speed a command produces, over all neutral feet.
float FastestFoot(const GaitCommand& c) {
  float fastest = 0.0f;
  for (int i = 0; i < kLegCount; ++i) {
    const float s =
        NormXY(GroundVelocity(c, TripodGait::Neutral(i, c.body_height_mm)));
    if (s > fastest) fastest = s;
  }
  return fastest;
}

GaitCommand Scaled(const GaitCommand& c, float k) {
  GaitCommand out = c;
  out.vx_mm_s *= k;
  out.vy_mm_s *= k;
  out.yaw_rate_rad_s *= k;
  return out;
}

GaitCommand Difference(const GaitCommand& a, const GaitCommand& b) {
  GaitCommand out = a;
  out.vx_mm_s -= b.vx_mm_s;
  out.vy_mm_s -= b.vy_mm_s;
  out.yaw_rate_rad_s -= b.yaw_rate_rad_s;
  return out;
}

float SmoothStep(float s) { return s * s * (3.0f - 2.0f * s); }

}  // namespace

Vec3 TripodGait::Neutral(int leg, float body_height_mm) {
  const Vec3 p = LegToBody(leg, Vec3{config::kNeutralReachMm, 0.0f, 0.0f});
  return {p.x, p.y, -body_height_mm};
}

void TripodGait::Reset(float body_height_mm) {
  for (int i = 0; i < kLegCount; ++i) {
    feet_[i] = Neutral(i, body_height_mm);
    liftoff_[i] = feet_[i];
    swing_[i] = false;
  }
  phase_ = 0.0f;
  idle_ = true;
  settle_boundaries_ = 0;
  applied_ = GaitCommand();
  applied_.body_height_mm = body_height_mm;
}

GaitCommand TripodGait::Limit(const GaitCommand& c) const {
  const float fastest = FastestFoot(c);
  return fastest > kMaxFootSpeedMmS ? Scaled(c, kMaxFootSpeedMmS / fastest) : c;
}

GaitCommand TripodGait::Ramp(const GaitCommand& target, float dt_s) const {
  const GaitCommand& now = applied_;
  const float now_speed = FastestFoot(now);

  // Slowing down along the same direction (joystick released, failsafe ramp)
  // only shortens the stance, so it applies at once: target == k * now.
  if (now_speed > 0.0f) {
    const float k = FastestFoot(target) / now_speed;
    if (k <= 1.0f && FastestFoot(Difference(target, Scaled(now, k))) < 0.5f) {
      return target;
    }
  }
  // Anything else (speeding up, turning, reversing) is acceleration-limited.
  const GaitCommand delta = Difference(target, now);
  const float change = FastestFoot(delta);
  const float allowed = kMaxFootAccelMmS2 * dt_s;
  if (change <= allowed) return target;
  GaitCommand out = now;
  const float k = allowed / change;
  out.vx_mm_s += delta.vx_mm_s * k;
  out.vy_mm_s += delta.vy_mm_s * k;
  out.yaw_rate_rad_s += delta.yaw_rate_rad_s * k;
  out.body_height_mm = target.body_height_mm;
  return out;
}

Vec3 TripodGait::Touchdown(int leg, const GaitCommand& c) const {
  // Land half a stance ahead, so the stance sweeps symmetrically over neutral.
  const Vec3 n = Neutral(leg, c.body_height_mm);
  return n - GroundVelocity(c, n) * (kStanceS / 2.0f);
}

void TripodGait::Update(const GaitCommand& command, float dt_s) {
  const GaitCommand c = Ramp(Limit(command), dt_s);
  applied_ = c;
  const bool moving =
      NormXY(Vec3{c.vx_mm_s, c.vy_mm_s, 0.0f}) > kMovingSpeedMmS ||
      fabsf(c.yaw_rate_rad_s) > kMovingYawRadS;

  if (idle_) {
    if (!moving) {
      for (int i = 0; i < kLegCount; ++i) feet_[i].z = -c.body_height_mm;
      return;
    }
    // Start mid-half-cycle: the first steps are half as long, so the stance
    // tripod (still at neutral) only travels half a stride before it swings.
    idle_ = false;
    phase_ = 0.25f;
    for (int i = 0; i < kLegCount; ++i) {
      swing_[i] = Group(i) == 0;
      liftoff_[i] = feet_[i];
      swing_start_[i] = phase_;
    }
  }
  if (moving) {
    settle_boundaries_ = 0;
  } else if (settle_boundaries_ == 0) {
    settle_boundaries_ = 2;  // finish this half-cycle, then step the others
  }

  const float old_phase = phase_;
  phase_ += dt_s / config::kGaitPeriodS;
  const bool crossed_half = old_phase < 0.5f && phase_ >= 0.5f;
  const bool crossed_end = phase_ >= 1.0f;
  if (crossed_end) phase_ -= 1.0f;

  for (int i = 0; i < kLegCount; ++i) {
    const bool swing = (Group(i) == 0) ? phase_ < 0.5f : phase_ >= 0.5f;
    if (swing && !swing_[i]) {
      liftoff_[i] = feet_[i];
      swing_start_[i] = Group(i) == 0 ? 0.0f : 0.5f;
    }
    if (!swing && swing_[i]) feet_[i] = Touchdown(i, c);  // land exactly
    swing_[i] = swing;

    if (swing) {
      const float end = Group(i) == 0 ? 0.5f : 1.0f;
      const float s = (phase_ - swing_start_[i]) / (end - swing_start_[i]);
      const Vec3 target = Touchdown(i, c);
      const float k = SmoothStep(s);
      feet_[i].x = liftoff_[i].x + (target.x - liftoff_[i].x) * k;
      feet_[i].y = liftoff_[i].y + (target.y - liftoff_[i].y) * k;
      feet_[i].z = -c.body_height_mm + config::kStepHeightMm * sinf(kPi * s);
    } else {
      Vec3 next = feet_[i] + GroundVelocity(c, feet_[i]) * dt_s;
      next.z = -c.body_height_mm;
      // Last resort: never leave the reachable stride (the foot slips).
      const Vec3 n = Neutral(i, c.body_height_mm);
      const float off = NormXY(next - n);
      if (off > config::kMaxHalfStrideMm) {
        const float k = config::kMaxHalfStrideMm / off;
        next.x = n.x + (next.x - n.x) * k;
        next.y = n.y + (next.y - n.y) * k;
      }
      feet_[i] = next;
    }
  }

  if ((crossed_half || crossed_end) && settle_boundaries_ > 0 &&
      --settle_boundaries_ == 0) {
    Reset(c.body_height_mm);  // every foot has just landed at neutral
  }
}

}  // namespace motion
}  // namespace hexapod
