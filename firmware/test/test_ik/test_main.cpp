// Native tests for leg kinematics.
#include <math.h>
#include <unity.h>

#include "config.h"
#include "motion/ik.h"

using hexapod::motion::BodyToLeg;
using hexapod::motion::ForwardLeg;
using hexapod::motion::JointAngles;
using hexapod::motion::kLegCount;
using hexapod::motion::LegToBody;
using hexapod::motion::Norm;
using hexapod::motion::RotateIntoBody;
using hexapod::motion::SolveLeg;
using hexapod::motion::Vec3;
using hexapod::motion::WithinLimits;
namespace config = hexapod::config;

void setUp() {}
void tearDown() {}

void test_forward_known_pose() {
  // Everything straight out: the foot is at the full reach on the x axis.
  const Vec3 p = ForwardLeg(JointAngles{0.0f, 0.0f, 0.0f});
  TEST_ASSERT_FLOAT_WITHIN(
      0.01f, config::kCoxaMm + config::kFemurMm + config::kTibiaMm, p.x);
  TEST_ASSERT_FLOAT_WITHIN(0.01f, 0.0f, p.y);
  TEST_ASSERT_FLOAT_WITHIN(0.01f, 0.0f, p.z);

  // Femur horizontal, tibia straight down: foot below the knee.
  const Vec3 q = ForwardLeg(JointAngles{0.0f, 0.0f, -90.0f});
  TEST_ASSERT_FLOAT_WITHIN(0.01f, config::kCoxaMm + config::kFemurMm, q.x);
  TEST_ASSERT_FLOAT_WITHIN(0.01f, -config::kTibiaMm, q.z);
}

// FK -> IK -> same angles, over the whole knee-up range inside the limits.
void test_round_trip_over_joint_space() {
  int checked = 0;
  // 0.5 deg inside each limit: exactly at a limit, float noise may land on
  // either side and the (strict) limit check rightly rejects it.
  for (float c = config::kCoxaMinDeg + 0.5f; c < config::kCoxaMaxDeg;
       c += 5.0f) {
    for (float f = config::kFemurMinDeg + 0.5f; f < config::kFemurMaxDeg;
         f += 5.0f) {
      for (float t = config::kTibiaMinDeg + 0.5f; t <= -5.0f; t += 5.0f) {
        const JointAngles in{c, f, t};
        // Skip feet behind (or over) the coxa axis: IK would turn the coxa
        // around, which is never a valid leg pose.
        const float planar = config::kCoxaMm +
                             config::kFemurMm * cosf(f * 0.0174533f) +
                             config::kTibiaMm * cosf((f + t) * 0.0174533f);
        if (planar < 5.0f) continue;
        const Vec3 foot = ForwardLeg(in);
        JointAngles out;
        TEST_ASSERT_TRUE_MESSAGE(SolveLeg(foot, &out),
                                 "reachable pose rejected");
        TEST_ASSERT_FLOAT_WITHIN(0.05f, in.coxa_deg, out.coxa_deg);
        TEST_ASSERT_FLOAT_WITHIN(0.05f, in.femur_deg, out.femur_deg);
        TEST_ASSERT_FLOAT_WITHIN(0.05f, in.tibia_deg, out.tibia_deg);
        ++checked;
      }
    }
  }
  TEST_ASSERT_TRUE(checked > 1000);
}

// Every foot position the gait may ask for is solvable within the limits:
// a disc of kMaxHalfStrideMm (+5 mm) around the neutral foot, at every body
// height, and the sit pose.
void test_workspace_within_limits() {
  const float r_max = config::kMaxHalfStrideMm + 5.0f;
  int checked = 0;
  for (float h = config::kBodyHeightMinMm; h <= config::kBodyHeightMaxMm;
       h += 10.0f) {
    for (float dx = -r_max; dx <= r_max; dx += 5.0f) {
      for (float dy = -r_max; dy <= r_max; dy += 5.0f) {
        if (dx * dx + dy * dy > r_max * r_max) continue;
        for (float lift = 0.0f; lift <= config::kStepHeightMm; lift += 15.0f) {
          const Vec3 foot{config::kNeutralReachMm + dx, dy, -h + lift};
          JointAngles a;
          TEST_ASSERT_TRUE_MESSAGE(SolveLeg(foot, &a),
                                   "workspace point unsolved");
          TEST_ASSERT_TRUE(WithinLimits(a));
          const Vec3 back = ForwardLeg(a);
          TEST_ASSERT_TRUE(Norm(back - foot) < 0.05f);
          ++checked;
        }
      }
    }
  }
  JointAngles sit;
  TEST_ASSERT_TRUE(
      SolveLeg(Vec3{config::kSitReachMm, 0.0f, -config::kSitHeightMm}, &sit));
  TEST_ASSERT_TRUE(checked > 500);
}

void test_unreachable_rejected() {
  JointAngles a{1.0f, 2.0f, 3.0f};
  const float too_far =
      config::kCoxaMm + config::kFemurMm + config::kTibiaMm + 10;
  TEST_ASSERT_FALSE(SolveLeg(Vec3{too_far, 0.0f, 0.0f}, &a));
  TEST_ASSERT_FALSE(SolveLeg(Vec3{0.0f, 160.0f, -100.0f}, &a));  // coxa 90 deg
  TEST_ASSERT_FALSE(SolveLeg(Vec3{160.0f, 0.0f, 120.0f}, &a));   // above body
  // Rejected solutions leave the output untouched.
  TEST_ASSERT_EQUAL_FLOAT(1.0f, a.coxa_deg);
  TEST_ASSERT_EQUAL_FLOAT(3.0f, a.tibia_deg);
}

void test_body_leg_frames() {
  for (int leg = 0; leg < kLegCount; ++leg) {
    const config::LegMount& m = config::kLegMounts[leg];
    // The coxa axis is the leg origin.
    const Vec3 origin = BodyToLeg(leg, Vec3{m.x_mm, m.y_mm, -50.0f});
    TEST_ASSERT_FLOAT_WITHIN(1e-3f, 0.0f, origin.x);
    TEST_ASSERT_FLOAT_WITHIN(1e-3f, 0.0f, origin.y);
    // Leg x points outward along the mount angle.
    const Vec3 out = LegToBody(leg, Vec3{100.0f, 0.0f, 0.0f});
    const float angle = atan2f(out.y - m.y_mm, out.x - m.x_mm) * 57.2958f;
    TEST_ASSERT_FLOAT_WITHIN(0.01f, m.angle_deg, angle);
    // Round trip.
    const Vec3 p{37.0f, -12.0f, -80.0f};
    TEST_ASSERT_TRUE(Norm(LegToBody(leg, BodyToLeg(leg, p)) - p) < 1e-3f);
  }
}

void test_body_rotation() {
  // Pitch +10 deg is nose-down: a point ahead of the body appears higher in it.
  const Vec3 ahead =
      RotateIntoBody(Vec3{100.0f, 0.0f, 0.0f}, 0.0f, 10.0f, 0.0f);
  TEST_ASSERT_TRUE(ahead.z > 0.0f);
  // Rotations preserve length and invert with the opposite angles.
  const Vec3 p{120.0f, -40.0f, -90.0f};
  const Vec3 r = RotateIntoBody(p, 7.0f, -5.0f, 12.0f);
  TEST_ASSERT_FLOAT_WITHIN(1e-3f, Norm(p), Norm(r));
  const Vec3 yaw_only =
      RotateIntoBody(Vec3{100.0f, 0.0f, 0.0f}, 0.0f, 0.0f, 90.0f);
  TEST_ASSERT_FLOAT_WITHIN(1e-3f, 0.0f, yaw_only.x);
  TEST_ASSERT_FLOAT_WITHIN(1e-3f, -100.0f, yaw_only.y);
}

int main() {
  UNITY_BEGIN();
  RUN_TEST(test_forward_known_pose);
  RUN_TEST(test_round_trip_over_joint_space);
  RUN_TEST(test_workspace_within_limits);
  RUN_TEST(test_unreachable_rejected);
  RUN_TEST(test_body_leg_frames);
  RUN_TEST(test_body_rotation);
  return UNITY_END();
}
