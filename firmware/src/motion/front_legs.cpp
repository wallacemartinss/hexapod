#include "motion/front_legs.h"

#include "config.h"
#include "motion/gait.h"

namespace hexapod {
namespace motion {
namespace {

// Gesture keyframes in normalized paw units.
struct Key {
  float t;  // s from the start
  PawInput paws;
};

constexpr Key kWave[] = {
    {0.0f, {0, 0, 0.3f, 1}},  {0.3f, {0, 0, 0.6f, 1}},
    {0.6f, {0, 0, -0.4f, 1}}, {0.9f, {0, 0, 0.6f, 1}},
    {1.2f, {0, 0, -0.4f, 1}}, {1.5f, {0, 0, 0.6f, 1}},
    {1.8f, {0, 0, -0.4f, 1}}, {2.2f, {0, 0, 0, 0}},
};
constexpr Key kGuard[] = {
    {0.0f, {-0.8f, 0.6f, -0.8f, 0.6f}},
    {1.6f, {-0.8f, 0.6f, -0.8f, 0.6f}},
    {2.0f, {0, 0, 0, 0}},
};
constexpr Key kStrike[] = {
    {0.0f, {-1, 0.8f, -1, 0.8f}},                                 // wind up
    {0.5f, {-1, 0.8f, -1, 0.8f}}, {0.75f, {1, -0.3f, 1, -0.3f}},  // strike
    {1.1f, {1, -0.3f, 1, -0.3f}}, {1.6f, {0, 0, 0, 0}},
};

template <int N>
constexpr int Count(const Key (&)[N]) {
  return N;
}

float Lerp(float a, float b, float k) { return a + (b - a) * k; }

// Paws along a keyframe track; false once the track is over.
bool Sample(const Key* keys, int n, float t, PawInput* out) {
  if (t >= keys[n - 1].t) return false;
  int i = 0;
  while (i + 1 < n && keys[i + 1].t <= t) ++i;
  const Key& a = keys[i];
  const Key& b = keys[i + 1];
  const float k = (t - a.t) / (b.t - a.t);
  out->left_reach = Lerp(a.paws.left_reach, b.paws.left_reach, k);
  out->left_lift = Lerp(a.paws.left_lift, b.paws.left_lift, k);
  out->right_reach = Lerp(a.paws.right_reach, b.paws.right_reach, k);
  out->right_lift = Lerp(a.paws.right_lift, b.paws.right_lift, k);
  return true;
}

float Clamp1(float v) { return v < -1.0f ? -1.0f : (v > 1.0f ? 1.0f : v); }

}  // namespace

Vec3 FrontLegs::PawPose(float reach, float lift) {
  return {config::kPawRestReachMm + Clamp1(reach) * config::kPawReachRangeMm,
          0.0f, config::kPawRestZMm + Clamp1(lift) * config::kPawLiftRangeMm};
}

PawInput FrontLegs::GesturePaws(const PawInput& sticks, float dt_s) {
  if (!playing()) return sticks;
  gesture_t_ += dt_s;
  PawInput out;
  bool running = false;
  switch (gesture_) {
    case hexapod_v1_Gesture_GESTURE_WAVE:
      running = Sample(kWave, Count(kWave), gesture_t_, &out);
      break;
    case hexapod_v1_Gesture_GESTURE_GUARD:
      running = Sample(kGuard, Count(kGuard), gesture_t_, &out);
      break;
    case hexapod_v1_Gesture_GESTURE_STRIKE:
      running = Sample(kStrike, Count(kStrike), gesture_t_, &out);
      break;
    default:
      break;
  }
  if (!running) {
    gesture_ = hexapod_v1_Gesture_GESTURE_UNSPECIFIED;
    return sticks;
  }
  return out;
}

void FrontLegs::Update(bool want, const PawInput& paws,
                       hexapod_v1_Gesture gesture, bool settled,
                       float body_height_mm, float dt_s, Vec3 feet[kLegCount]) {
  const bool done = at_end_ && settled;
  if (phase_ == Phase::kOff && want) {
    for (int i = 0; i < kLegCount; ++i) {
      cmd_[i] = TripodGait::Neutral(i, body_height_mm);
    }
  }

  // A gesture starts on the edge from "none" to a value, with the paws up.
  if (gesture != last_input_ &&
      gesture != hexapod_v1_Gesture_GESTURE_UNSPECIFIED &&
      phase_ == Phase::kActive) {
    gesture_ = gesture;
    gesture_t_ = 0.0f;
  }
  last_input_ = gesture;

  switch (phase_) {
    case Phase::kOff:
      if (want) phase_ = Phase::kShift;
      break;
    case Phase::kShift:
      if (!want) {
        phase_ = Phase::kUnshift;
      } else if (done) {
        phase_ = Phase::kHover;
      }
      break;
    case Phase::kHover:
      if (!want) {
        phase_ = Phase::kLower;
      } else if (done) {
        phase_ = Phase::kRaise;
      }
      break;
    case Phase::kRaise:
      if (!want) {
        phase_ = Phase::kDescend;
      } else if (done) {
        phase_ = Phase::kActive;
      }
      break;
    case Phase::kActive:
      if (!want) {
        gesture_ = hexapod_v1_Gesture_GESTURE_UNSPECIFIED;
        phase_ = Phase::kDescend;
      }
      break;
    case Phase::kDescend:
      if (want) {
        phase_ = Phase::kRaise;
      } else if (done) {
        phase_ = Phase::kLower;
      }
      break;
    case Phase::kLower:
      if (want) {
        phase_ = Phase::kHover;
      } else if (done) {
        phase_ = Phase::kUnshift;
      }
      break;
    case Phase::kUnshift:
      if (want) {
        phase_ = Phase::kShift;
      } else if (done) {
        phase_ = Phase::kOff;
      }
      break;
  }
  if (phase_ == Phase::kOff) return;

  // End positions of this phase. Body back = every foot forward in the body
  // frame.
  const float shift =
      phase_ == Phase::kUnshift ? 0.0f : config::kFrontLegsShiftMm;
  Vec3 end[kLegCount];
  for (int i = 0; i < kLegCount; ++i) {
    end[i] = TripodGait::Neutral(i, body_height_mm) + Vec3{shift, 0.0f, 0.0f};
  }

  const PawInput p = GesturePaws(paws, dt_s);
  constexpr int kPaws[] = {kLeftPaw, kRightPaw};
  for (const int leg : kPaws) {
    const bool left = leg == kLeftPaw;
    switch (phase_) {
      case Phase::kHover:
      case Phase::kDescend:
        end[leg].z += config::kPawHoverMm;
        break;
      case Phase::kRaise:
        end[leg] = LegToBody(leg, PawPose(0.0f, 0.0f));
        break;
      case Phase::kActive:
        end[leg] = LegToBody(leg, left ? PawPose(p.left_reach, p.left_lift)
                                       : PawPose(p.right_reach, p.right_lift));
        break;
      default:
        break;  // on the ground
    }
  }

  // Straight-line steps: sliding feet stay on the ground, paws go straight
  // up and down.
  const bool sliding = phase_ == Phase::kShift || phase_ == Phase::kUnshift;
  const float step =
      (sliding ? config::kBodyShiftSpeedMmS : config::kPawSpeedMmS) * dt_s;
  at_end_ = true;
  for (int i = 0; i < kLegCount; ++i) {
    const Vec3 d = end[i] - cmd_[i];
    const float dist = Norm(d);
    if (dist > step) {
      cmd_[i] = cmd_[i] + d * (step / dist);
      at_end_ = false;
    } else {
      cmd_[i] = end[i];
    }
    feet[i] = cmd_[i];
  }
}

}  // namespace motion
}  // namespace hexapod
