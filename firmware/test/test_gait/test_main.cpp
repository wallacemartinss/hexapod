// Native tests for the tripod gait and the motion controller.
#include <math.h>
#include <unity.h>

#include "config.h"
#include "motion/controller.h"
#include "motion/gait.h"
#include "motion/ik.h"

using hexapod::motion::BodyToLeg;
using hexapod::motion::GaitCommand;
using hexapod::motion::JointAngles;
using hexapod::motion::kLegCount;
using hexapod::motion::MotionController;
using hexapod::motion::MotionInput;
using hexapod::motion::NormXY;
using hexapod::motion::SolveLeg;
using hexapod::motion::TripodGait;
using hexapod::motion::Vec3;
namespace config = hexapod::config;
namespace safety = hexapod::safety;

void setUp() {}
void tearDown() {}

namespace {

constexpr float kDt = config::kMotionPeriodMs / 1000.0f;
constexpr float kHeight = 100.0f;

// Deterministic pseudo-random numbers in [-1, 1].
struct Lcg {
  uint32_t state = 12345;
  float Next() {
    state = state * 1664525u + 1013904223u;
    return static_cast<float>(state >> 8) / 8388608.0f - 1.0f;
  }
};

GaitCommand Walk(float vx, float vy, float yaw_deg_s) {
  GaitCommand c;
  c.vx_mm_s = vx;
  c.vy_mm_s = vy;
  c.yaw_rate_rad_s = yaw_deg_s * 0.0174533f;
  c.body_height_mm = kHeight;
  return c;
}

// Invariants that must hold after every gait update.
void CheckTripod(const TripodGait& g, float height) {
  int stance = 0;
  int swing_group = -1;
  for (int i = 0; i < kLegCount; ++i) {
    const Vec3& f = g.foot(i);
    if (g.swinging(i)) {
      // All swinging legs belong to the same tripod.
      if (swing_group < 0) swing_group = TripodGait::Group(i);
      TEST_ASSERT_EQUAL_INT(swing_group, TripodGait::Group(i));
      TEST_ASSERT_TRUE(f.z >= -height - 1e-3f);
    } else {
      ++stance;
      TEST_ASSERT_FLOAT_WITHIN(1e-3f, -height, f.z);
    }
    // The foot stays near its neutral spot and is reachable.
    const Vec3 n = TripodGait::Neutral(i, height);
    TEST_ASSERT_TRUE(NormXY(f - n) <= config::kMaxHalfStrideMm + 1.0f);
    JointAngles a;
    TEST_ASSERT_TRUE_MESSAGE(SolveLeg(BodyToLeg(i, f), &a), "foot unreachable");
  }
  TEST_ASSERT_TRUE_MESSAGE(stance >= 3, "fewer than 3 feet on the ground");
}

safety::Output Follow() {
  safety::Output o;
  o.state = hexapod_v1_State_STATE_NORMAL;
  o.posture = safety::Posture::kFollow;
  o.servos_enabled = true;
  o.speed_scale = 1.0f;
  return o;
}

}  // namespace

void test_tripod_always_three_feet_down() {
  TripodGait g;
  g.Reset(kHeight);
  Lcg rng;
  GaitCommand c = Walk(0, 0, 0);
  // Two minutes of random commands, changed every second, stops included.
  for (int tick = 0; tick < 6000; ++tick) {
    if (tick % 50 == 0) {
      const bool stop = rng.Next() > 0.6f;
      c = stop ? Walk(0, 0, 0)
               : Walk(rng.Next() * config::kMaxSpeedMmS,
                      rng.Next() * config::kMaxSpeedMmS,
                      rng.Next() * config::kMaxYawRateDegS);
    }
    g.Update(c, kDt);
    CheckTripod(g, kHeight);
  }
}

void test_stance_feet_move_against_the_body() {
  TripodGait g;
  g.Reset(kHeight);
  const GaitCommand forward = Walk(60.0f, 0.0f, 0.0f);
  // Speeding up is acceleration-limited: let it reach 60 mm/s first.
  for (int tick = 0; tick < 150; ++tick) g.Update(forward, kDt);
  TEST_ASSERT_FLOAT_WITHIN(1e-3f, 60.0f, g.applied().vx_mm_s);
  for (int tick = 0; tick < 100; ++tick) {
    Vec3 before[kLegCount];
    bool was_swinging[kLegCount];
    for (int i = 0; i < kLegCount; ++i) {
      before[i] = g.foot(i);
      was_swinging[i] = g.swinging(i);
    }
    g.Update(forward, kDt);
    for (int i = 0; i < kLegCount; ++i) {
      if (!g.swinging(i) && !was_swinging[i]) {
        // Body goes +x at 60 mm/s: planted feet slide -x by 1.2 mm per tick.
        TEST_ASSERT_FLOAT_WITHIN(1e-3f, -60.0f * kDt,
                                 g.foot(i).x - before[i].x);
      }
    }
  }
}

void test_stops_and_settles_at_neutral() {
  TripodGait g;
  g.Reset(kHeight);
  for (int tick = 0; tick < 137; ++tick) g.Update(Walk(70, 20, 10), kDt);
  TEST_ASSERT_FALSE(g.idle());
  int ticks = 0;
  while (!g.idle() && ticks < 200) {
    g.Update(Walk(0, 0, 0), kDt);
    CheckTripod(g, kHeight);
    ++ticks;
  }
  TEST_ASSERT_TRUE(g.idle());
  // At most the rest of this half-cycle plus one more.
  TEST_ASSERT_TRUE(ticks <= static_cast<int>(config::kGaitPeriodS / kDt) + 1);
  for (int i = 0; i < kLegCount; ++i) {
    const Vec3 n = TripodGait::Neutral(i, kHeight);
    TEST_ASSERT_TRUE(NormXY(g.foot(i) - n) < 0.5f);
    TEST_ASSERT_FALSE(g.swinging(i));
  }
  // Idle with a zero command: nothing moves.
  const Vec3 f0 = g.foot(0);
  for (int tick = 0; tick < 100; ++tick) g.Update(Walk(0, 0, 0), kDt);
  TEST_ASSERT_TRUE(NormXY(g.foot(0) - f0) < 1e-4f);
}

void test_speeding_up_is_gradual_slowing_down_is_not() {
  TripodGait g;
  g.Reset(kHeight);
  g.Update(Walk(80.0f, 0.0f, 0.0f), kDt);
  TEST_ASSERT_TRUE(g.applied().vx_mm_s < 5.0f);  // one tick: barely moving
  for (int tick = 0; tick < 150; ++tick) g.Update(Walk(80.0f, 0.0f, 0.0f), kDt);
  TEST_ASSERT_FLOAT_WITHIN(1e-3f, 80.0f, g.applied().vx_mm_s);
  g.Update(Walk(20.0f, 0.0f, 0.0f), kDt);  // same direction, slower: at once
  TEST_ASSERT_FLOAT_WITHIN(1e-3f, 20.0f, g.applied().vx_mm_s);
  g.Update(Walk(-20.0f, 0.0f, 0.0f), kDt);  // reversing: gradual
  TEST_ASSERT_TRUE(g.applied().vx_mm_s > 15.0f);
}

void test_excessive_command_is_limited() {
  TripodGait g;
  g.Reset(kHeight);
  for (int tick = 0; tick < 500; ++tick) {
    g.Update(Walk(500.0f, -300.0f, 200.0f), kDt);  // far beyond the limits
    CheckTripod(g, kHeight);
  }
  TEST_ASSERT_TRUE(g.applied().vx_mm_s < 500.0f);
}

void test_controller_starts_seated_and_stands_smoothly() {
  MotionController m;
  TEST_ASSERT_TRUE(m.sitting());
  MotionInput in;
  in.mode = hexapod_v1_Mode_MODE_STAND;
  in.body_height = 0.5f;
  const float max_step = config::kMaxJointSpeedDegS * kDt + 1e-3f;
  JointAngles prev[kLegCount];
  for (int i = 0; i < kLegCount; ++i) prev[i] = m.joints(i);
  for (int tick = 0; tick < 150; ++tick) {
    m.Update(in, Follow(), kDt);
    for (int i = 0; i < kLegCount; ++i) {
      TEST_ASSERT_TRUE(fabsf(m.joints(i).femur_deg - prev[i].femur_deg) <=
                       max_step);
      TEST_ASSERT_TRUE(fabsf(m.joints(i).tibia_deg - prev[i].tibia_deg) <=
                       max_step);
      TEST_ASSERT_TRUE(fabsf(m.joints(i).coxa_deg - prev[i].coxa_deg) <=
                       max_step);
      prev[i] = m.joints(i);
    }
  }
  TEST_ASSERT_FALSE(m.sitting());
  TEST_ASSERT_EQUAL_HEX8(0, m.ik_fail_mask());
  // Reached the standing pose.
  JointAngles stand;
  const float h = (config::kBodyHeightMinMm + config::kBodyHeightMaxMm) / 2.0f;
  TEST_ASSERT_TRUE(SolveLeg(BodyToLeg(0, TripodGait::Neutral(0, h)), &stand));
  TEST_ASSERT_FLOAT_WITHIN(0.01f, stand.femur_deg, m.joints(0).femur_deg);
  TEST_ASSERT_FLOAT_WITHIN(0.01f, stand.tibia_deg, m.joints(0).tibia_deg);
}

void test_failsafe_sit_finishes_step_then_sits() {
  MotionController m;
  MotionInput in;
  in.mode = hexapod_v1_Mode_MODE_WALK;
  in.vx = 1.0f;
  for (int tick = 0; tick < 200; ++tick) m.Update(in, Follow(), kDt);
  TEST_ASSERT_FALSE(m.sitting());

  safety::Output sit = Follow();
  sit.state = hexapod_v1_State_STATE_SAFE_SIT;
  sit.posture = safety::Posture::kSit;
  sit.speed_scale = 0.0f;
  int ticks = 0;
  while (!m.sitting() && ticks < 200) {
    m.Update(in, sit, kDt);
    ++ticks;
  }
  TEST_ASSERT_TRUE(m.sitting());
  TEST_ASSERT_TRUE(ticks <= static_cast<int>(config::kGaitPeriodS / kDt) + 1);
}

void test_relax_holds_joints() {
  MotionController m;
  MotionInput in;
  in.mode = hexapod_v1_Mode_MODE_STAND;
  for (int tick = 0; tick < 20; ++tick) m.Update(in, Follow(), kDt);
  const JointAngles held = m.joints(3);
  safety::Output relax;  // default: RELAXED, no torque
  in.mode = hexapod_v1_Mode_MODE_WALK;
  in.vx = 1.0f;
  for (int tick = 0; tick < 100; ++tick) m.Update(in, relax, kDt);
  TEST_ASSERT_EQUAL_FLOAT(held.femur_deg, m.joints(3).femur_deg);
  TEST_ASSERT_EQUAL_FLOAT(held.tibia_deg, m.joints(3).tibia_deg);
}

void test_blocked_front_stops_forward_walk() {
  MotionController blocked_ctl;
  MotionController free_ctl;
  MotionInput in;
  in.mode = hexapod_v1_Mode_MODE_WALK;
  in.vx = 1.0f;
  safety::Output blocked = Follow();
  blocked.blocked_mask = 0x1;  // front
  for (int tick = 0; tick < 300; ++tick) {
    blocked_ctl.Update(in, blocked, kDt);
    free_ctl.Update(in, Follow(), kDt);
  }
  // Blocked: standing still (gait idle -> coxa back at its neutral angle).
  JointAngles stand;
  const float h = (config::kBodyHeightMinMm + config::kBodyHeightMaxMm) / 2.0f;
  TEST_ASSERT_TRUE(SolveLeg(BodyToLeg(0, TripodGait::Neutral(0, h)), &stand));
  TEST_ASSERT_FLOAT_WITHIN(0.01f, stand.coxa_deg,
                           blocked_ctl.joints(0).coxa_deg);
  TEST_ASSERT_TRUE(fabsf(free_ctl.joints(0).coxa_deg - stand.coxa_deg) > 0.5f ||
                   fabsf(free_ctl.joints(0).femur_deg - stand.femur_deg) >
                       0.5f);
}

int main() {
  UNITY_BEGIN();
  RUN_TEST(test_tripod_always_three_feet_down);
  RUN_TEST(test_stance_feet_move_against_the_body);
  RUN_TEST(test_stops_and_settles_at_neutral);
  RUN_TEST(test_speeding_up_is_gradual_slowing_down_is_not);
  RUN_TEST(test_excessive_command_is_limited);
  RUN_TEST(test_controller_starts_seated_and_stands_smoothly);
  RUN_TEST(test_failsafe_sit_finishes_step_then_sits);
  RUN_TEST(test_relax_holds_joints);
  RUN_TEST(test_blocked_front_stops_forward_walk);
  return UNITY_END();
}
