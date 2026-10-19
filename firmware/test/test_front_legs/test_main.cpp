// Native tests for the front legs mode: safe ordering, paw workspace,
// gestures and leaving the mode.
#include <math.h>
#include <unity.h>

#include "config.h"
#include "motion/controller.h"
#include "motion/front_legs.h"
#include "motion/gait.h"
#include "motion/ik.h"

using hexapod::motion::BodyToLeg;
using hexapod::motion::ForwardLeg;
using hexapod::motion::FrontLegs;
using hexapod::motion::JointAngles;
using hexapod::motion::kLegCount;
using hexapod::motion::LegToBody;
using hexapod::motion::MotionController;
using hexapod::motion::MotionInput;
using hexapod::motion::SolveLeg;
using hexapod::motion::TripodGait;
using hexapod::motion::Vec3;
namespace config = hexapod::config;
namespace safety = hexapod::safety;
using Phase = FrontLegs::Phase;

void setUp() {}
void tearDown() {}

namespace {

constexpr float kDt = config::kMotionPeriodMs / 1000.0f;
const float kHeight =
    (config::kBodyHeightMinMm + config::kBodyHeightMaxMm) / 2.0f;

safety::Output Follow() {
  safety::Output o;
  o.state = hexapod_v1_State_STATE_NORMAL;
  o.posture = safety::Posture::kFollow;
  o.servos_enabled = true;
  o.speed_scale = 1.0f;
  return o;
}

// Where the foot of `leg` actually is (from the joints, not the targets).
Vec3 FootNow(const MotionController& m, int leg) {
  return LegToBody(leg, ForwardLeg(m.joints(leg)));
}

bool PawUp(const MotionController& m, int leg) {
  return FootNow(m, leg).z > -kHeight + 2.0f;
}

// Support feet are at their shifted spot (body moved back).
bool BodyBack(const MotionController& m) {
  constexpr int kSupport[] = {1, 2, 4, 5};
  for (int leg : kSupport) {
    const Vec3 want = TripodGait::Neutral(leg, kHeight) +
                      Vec3{config::kFrontLegsShiftMm, 0.0f, 0.0f};
    const Vec3 now = FootNow(m, leg);
    if (fabsf(now.x - want.x) > 2.0f || fabsf(now.y - want.y) > 2.0f) {
      return false;
    }
  }
  return true;
}

void StandUp(MotionController& m) {
  MotionInput in;
  in.mode = hexapod_v1_Mode_MODE_STAND;
  for (int i = 0; i < 100; ++i) m.Update(in, Follow(), kDt);
}

// Runs until the front legs reach `phase` (or fails after `max_ticks`),
// checking the safety invariant on every tick.
void RunUntil(MotionController& m, const MotionInput& in, Phase phase,
              int max_ticks, const safety::Output& fs = Follow()) {
  for (int i = 0; i < max_ticks; ++i) {
    m.Update(in, fs, kDt);
    // Before the mode takes over, a front leg in the air is a gait step.
    const bool paw_up =
        m.front_legs().active() &&
        (PawUp(m, FrontLegs::kLeftPaw) || PawUp(m, FrontLegs::kRightPaw));
    TEST_ASSERT_FALSE_MESSAGE(paw_up && !BodyBack(m),
                              "a paw is off the ground with the body forward");
    TEST_ASSERT_EQUAL_HEX8(0, m.ik_fail_mask());
    if (m.front_legs().phase() == phase && m.settled()) return;
  }
  TEST_FAIL_MESSAGE("phase not reached in time");
}

MotionInput Legs() {
  MotionInput in;
  in.mode = hexapod_v1_Mode_MODE_FRONT_LEGS;
  return in;
}

}  // namespace

void test_paw_workspace_within_limits() {
  for (float reach = -1.0f; reach <= 1.0f; reach += 0.1f) {
    for (float lift = -1.0f; lift <= 1.0f; lift += 0.1f) {
      JointAngles a;
      TEST_ASSERT_TRUE_MESSAGE(SolveLeg(FrontLegs::PawPose(reach, lift), &a),
                               "paw pose out of reach");
    }
  }
  // Shifted stance at every body height, and the hover point.
  for (float h = config::kBodyHeightMinMm; h <= config::kBodyHeightMaxMm;
       h += 5.0f) {
    for (int leg = 0; leg < kLegCount; ++leg) {
      Vec3 foot = TripodGait::Neutral(leg, h) +
                  Vec3{config::kFrontLegsShiftMm, 0.0f, 0.0f};
      JointAngles a;
      TEST_ASSERT_TRUE(SolveLeg(BodyToLeg(leg, foot), &a));
      if (leg != FrontLegs::kLeftPaw && leg != FrontLegs::kRightPaw) continue;
      foot.z += config::kPawHoverMm;  // only the paws hover
      TEST_ASSERT_TRUE(SolveLeg(BodyToLeg(leg, foot), &a));
    }
  }
}

void test_enter_shifts_body_before_lifting_paws() {
  MotionController m;
  StandUp(m);
  m.Update(Legs(), Follow(), kDt);
  TEST_ASSERT_EQUAL_INT(Phase::kShift, m.front_legs().phase());
  TEST_ASSERT_FALSE(PawUp(m, FrontLegs::kLeftPaw));
  RunUntil(m, Legs(), Phase::kActive, 400);
  TEST_ASSERT_TRUE(BodyBack(m));
  TEST_ASSERT_TRUE(PawUp(m, FrontLegs::kLeftPaw));
  TEST_ASSERT_TRUE(PawUp(m, FrontLegs::kRightPaw));
}

void test_sticks_move_each_paw() {
  MotionController m;
  StandUp(m);
  RunUntil(m, Legs(), Phase::kActive, 400);
  const Vec3 rest_left = FootNow(m, FrontLegs::kLeftPaw);
  const Vec3 rest_right = FootNow(m, FrontLegs::kRightPaw);

  MotionInput in = Legs();
  in.paws.left_lift = 1.0f;     // left paw up
  in.paws.right_reach = -1.0f;  // right paw in towards the body
  for (int i = 0; i < 100; ++i) m.Update(in, Follow(), kDt);
  TEST_ASSERT_TRUE(FootNow(m, FrontLegs::kLeftPaw).z >
                   rest_left.z + config::kPawLiftRangeMm - 2.0f);
  const Vec3 rr = BodyToLeg(FrontLegs::kRightPaw, rest_right);
  const Vec3 rn =
      BodyToLeg(FrontLegs::kRightPaw, FootNow(m, FrontLegs::kRightPaw));
  TEST_ASSERT_FLOAT_WITHIN(1.0f, rr.x - config::kPawReachRangeMm, rn.x);
}

void test_gesture_plays_once_on_edge() {
  MotionController m;
  StandUp(m);
  RunUntil(m, Legs(), Phase::kActive, 400);
  MotionInput in = Legs();
  in.gesture = hexapod_v1_Gesture_GESTURE_WAVE;
  m.Update(in, Follow(), kDt);
  TEST_ASSERT_TRUE(m.front_legs().playing());
  float max_z = -1000.0f;
  int ticks = 0;
  while (m.front_legs().playing() && ticks < 500) {
    m.Update(in, Follow(), kDt);  // still WAVE: no restart
    max_z = fmaxf(max_z, FootNow(m, FrontLegs::kRightPaw).z);
    ++ticks;
  }
  TEST_ASSERT_FALSE(m.front_legs().playing());
  TEST_ASSERT_TRUE(ticks > 50);  // ~2.2 s
  TEST_ASSERT_TRUE(max_z >
                   config::kPawRestZMm + 0.5f * config::kPawLiftRangeMm);
  // Holding the same value does not replay it; none -> wave does.
  for (int i = 0; i < 20; ++i) m.Update(in, Follow(), kDt);
  TEST_ASSERT_FALSE(m.front_legs().playing());
  in.gesture = hexapod_v1_Gesture_GESTURE_UNSPECIFIED;
  m.Update(in, Follow(), kDt);
  in.gesture = hexapod_v1_Gesture_GESTURE_STRIKE;
  m.Update(in, Follow(), kDt);
  TEST_ASSERT_TRUE(m.front_legs().playing());
}

void test_leaving_lowers_paws_before_body_comes_forward() {
  MotionController m;
  StandUp(m);
  RunUntil(m, Legs(), Phase::kActive, 400);
  MotionInput stand;
  stand.mode = hexapod_v1_Mode_MODE_STAND;
  RunUntil(m, stand, Phase::kUnshift, 400);
  TEST_ASSERT_FALSE(PawUp(m, FrontLegs::kLeftPaw));
  TEST_ASSERT_FALSE(PawUp(m, FrontLegs::kRightPaw));
  RunUntil(m, stand, Phase::kOff, 400);
  TEST_ASSERT_FALSE(m.front_legs().active());
  TEST_ASSERT_FALSE(m.sitting());
}

void test_failsafe_sit_lowers_paws_then_sits() {
  MotionController m;
  StandUp(m);
  RunUntil(m, Legs(), Phase::kActive, 400);
  safety::Output sit = Follow();
  sit.state = hexapod_v1_State_STATE_SAFE_SIT;
  sit.posture = safety::Posture::kSit;
  RunUntil(m, Legs(), Phase::kOff, 600, sit);
  int ticks = 0;
  while (!m.sitting() && ticks++ < 100) m.Update(Legs(), sit, kDt);
  TEST_ASSERT_TRUE(m.sitting());
}

void test_walking_stops_before_front_legs() {
  MotionController m;
  StandUp(m);
  MotionInput walk;
  walk.mode = hexapod_v1_Mode_MODE_WALK;
  walk.vx = 1.0f;
  for (int i = 0; i < 150; ++i) m.Update(walk, Follow(), kDt);
  // Switching while mid-stride: the gait settles first, then the shift.
  RunUntil(m, Legs(), Phase::kActive, 600);
}

int main() {
  UNITY_BEGIN();
  RUN_TEST(test_paw_workspace_within_limits);
  RUN_TEST(test_enter_shifts_body_before_lifting_paws);
  RUN_TEST(test_sticks_move_each_paw);
  RUN_TEST(test_gesture_plays_once_on_edge);
  RUN_TEST(test_leaving_lowers_paws_before_body_comes_forward);
  RUN_TEST(test_failsafe_sit_lowers_paws_then_sits);
  RUN_TEST(test_walking_stops_before_front_legs);
  return UNITY_END();
}
