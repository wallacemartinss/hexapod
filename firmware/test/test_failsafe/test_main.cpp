// Native tests for the failsafe state machine: every transition of
// CLAUDE.md section 6.
#include <unity.h>

#include "config.h"
#include "safety/failsafe.h"

using hexapod::safety::ClampVelocity;
using hexapod::safety::CommandInput;
using hexapod::safety::Failsafe;
using hexapod::safety::Output;
using hexapod::safety::Posture;
using hexapod::safety::SensorInputs;
namespace config = hexapod::config;

void setUp() {}
void tearDown() {}

namespace {

constexpr uint32_t kTick = config::kMotionPeriodMs;

// Healthy robot: level, 3.8 V/cell, 1 A, nothing within 1 m.
SensorInputs Healthy() {
  SensorInputs s;
  s.imu_valid = true;
  s.battery_valid = true;
  s.battery_voltage_v = 3.8f * config::kBatteryCells;
  s.current_valid = true;
  s.current_a = 1.0f;
  s.distances_valid_mask = 0x0F;
  for (auto& d : s.distances_mm) d = 1000;
  return s;
}

// Test fixture: a clock, a failsafe and a pilot sending commands.
struct Rig {
  Failsafe fs;
  SensorInputs sensors = Healthy();
  uint32_t now = 1000;
  uint32_t seq = 0;

  explicit Rig(
      hexapod_v1_LinkProfile p = hexapod_v1_LinkProfile_LINK_PROFILE_WIFI)
      : fs(p) {}

  bool Send(hexapod_v1_Mode mode = hexapod_v1_Mode_MODE_WALK,
            bool estop = false) {
    CommandInput c;
    c.seq = ++seq;
    c.mode = mode;
    c.estop = estop;
    return fs.OnCommand(c, now);
  }
  const Output& Tick() { return fs.Update(sensors, now); }
  // Advances `ms` running the 50 Hz loop; the pilot keeps talking if asked.
  const Output& Run(uint32_t ms, bool pilot = false) {
    for (uint32_t t = 0; t < ms; t += kTick) {
      now += kTick;
      if (pilot) Send();
      Tick();
    }
    return fs.output();
  }
  // Boot -> STAND -> NORMAL.
  void Stand() {
    Send(hexapod_v1_Mode_MODE_STAND);
    Tick();
  }
};

void AssertState(hexapod_v1_State expected, const Output& out) {
  TEST_ASSERT_EQUAL_INT(expected, out.state);
}

}  // namespace

void test_boot_is_relaxed_until_stand() {
  Rig r;
  const Output& out = r.Tick();
  AssertState(hexapod_v1_State_STATE_RELAXED, out);
  TEST_ASSERT_FALSE(out.servos_enabled);

  r.Send(hexapod_v1_Mode_MODE_WALK);  // commands without STAND do not wake it
  AssertState(hexapod_v1_State_STATE_RELAXED, r.Tick());

  r.Stand();
  AssertState(hexapod_v1_State_STATE_NORMAL, r.fs.output());
  TEST_ASSERT_TRUE(r.fs.output().servos_enabled);
  TEST_ASSERT_EQUAL_FLOAT(1.0f, r.fs.output().speed_scale);
}

void test_steady_commands_stay_normal() {
  Rig r;
  r.Stand();
  AssertState(hexapod_v1_State_STATE_NORMAL, r.Run(5000, true));
}

void test_wifi_link_loss_escalation() {
  Rig r;
  r.Stand();
  const uint32_t t0 = r.now;  // last valid command

  r.now = t0 + 150;  // exactly at the limit: still fine
  AssertState(hexapod_v1_State_STATE_NORMAL, r.Tick());

  r.now = t0 + 160;
  const Output& stopping = r.Tick();
  AssertState(hexapod_v1_State_STATE_STOPPING, stopping);
  TEST_ASSERT_EQUAL_INT(Posture::kStop, stopping.posture);
  TEST_ASSERT_TRUE(stopping.speed_scale > 0.9f);  // ramp just started

  r.now = t0 + 160 + 150;  // half of the 300 ms ramp
  TEST_ASSERT_FLOAT_WITHIN(0.05f, 0.5f, r.Tick().speed_scale);

  r.now = t0 + 480;  // ramp over, before SAFE_SIT
  TEST_ASSERT_EQUAL_FLOAT(0.0f, r.Tick().speed_scale);
  AssertState(hexapod_v1_State_STATE_STOPPING, r.fs.output());

  r.now = t0 + 510;
  const Output& sit = r.Tick();
  AssertState(hexapod_v1_State_STATE_SAFE_SIT, sit);
  TEST_ASSERT_EQUAL_INT(Posture::kSit, sit.posture);
  TEST_ASSERT_TRUE(sit.servos_enabled);

  r.now = t0 + 10000;
  AssertState(hexapod_v1_State_STATE_SAFE_SIT, r.Tick());
  r.now = t0 + 10010;
  const Output& relaxed = r.Tick();
  AssertState(hexapod_v1_State_STATE_RELAXED, relaxed);
  TEST_ASSERT_FALSE(relaxed.servos_enabled);
}

void test_cellular_link_loss_thresholds() {
  Rig r(hexapod_v1_LinkProfile_LINK_PROFILE_CELLULAR);
  r.Stand();
  const uint32_t t0 = r.now;
  r.now = t0 + 390;
  AssertState(hexapod_v1_State_STATE_NORMAL, r.Tick());
  r.now = t0 + 410;
  AssertState(hexapod_v1_State_STATE_STOPPING, r.Tick());
  r.now = t0 + 1490;
  AssertState(hexapod_v1_State_STATE_STOPPING, r.Tick());
  r.now = t0 + 1510;
  AssertState(hexapod_v1_State_STATE_SAFE_SIT, r.Tick());
  r.now = t0 + 10010;
  AssertState(hexapod_v1_State_STATE_RELAXED, r.Tick());
}

void test_recovery_is_never_automatic() {
  Rig r;
  r.Stand();
  r.Run(200);  // silence -> STOPPING
  AssertState(hexapod_v1_State_STATE_STOPPING, r.fs.output());

  // Link is back, but the pilot keeps sending WALK: stays stopped.
  const Output& out = r.Run(2000, true);
  AssertState(hexapod_v1_State_STATE_STOPPING, out);
  TEST_ASSERT_EQUAL_FLOAT(0.0f, out.speed_scale);

  r.Stand();
  AssertState(hexapod_v1_State_STATE_NORMAL, r.fs.output());
}

void test_stand_recovers_from_safe_sit_and_relaxed() {
  Rig r;
  r.Stand();
  r.Run(600);
  AssertState(hexapod_v1_State_STATE_SAFE_SIT, r.fs.output());
  r.Stand();
  AssertState(hexapod_v1_State_STATE_NORMAL, r.fs.output());

  r.Run(10100);
  AssertState(hexapod_v1_State_STATE_RELAXED, r.fs.output());
  r.Stand();
  AssertState(hexapod_v1_State_STATE_NORMAL, r.fs.output());
}

void test_stale_or_repeated_seq_is_not_valid() {
  Rig r;
  r.Stand();
  const uint32_t t0 = r.now;
  CommandInput replay;
  replay.seq = r.seq;  // same seq again
  replay.mode = hexapod_v1_Mode_MODE_WALK;
  r.now = t0 + 100;
  TEST_ASSERT_FALSE(r.fs.OnCommand(replay, r.now));
  replay.seq = r.seq - 1;  // older
  TEST_ASSERT_FALSE(r.fs.OnCommand(replay, r.now));
  r.now = t0 + 160;  // replays did not refresh the timer
  AssertState(hexapod_v1_State_STATE_STOPPING, r.Tick());
  TEST_ASSERT_EQUAL_UINT32(r.seq, r.fs.last_command_seq());
}

void test_estop_latches_even_with_stale_seq() {
  Rig r;
  r.Stand();
  CommandInput stop;
  stop.seq = 1;  // stale on purpose
  stop.estop = true;
  TEST_ASSERT_FALSE(r.fs.OnCommand(stop, r.now));
  const Output& out = r.Tick();
  AssertState(hexapod_v1_State_STATE_ESTOP, out);
  TEST_ASSERT_FALSE(out.servos_enabled);

  // Normal commands do not clear it.
  AssertState(hexapod_v1_State_STATE_ESTOP, r.Run(1000, true));
  // A STAND that still carries estop does not clear it either.
  r.Send(hexapod_v1_Mode_MODE_STAND, true);
  AssertState(hexapod_v1_State_STATE_ESTOP, r.Tick());

  r.Stand();
  AssertState(hexapod_v1_State_STATE_NORMAL, r.fs.output());
}

void test_tipped_relaxes_and_needs_level_to_recover() {
  Rig r;
  r.Stand();
  r.sensors.roll_deg = 40.0f;
  r.Run(60, true);  // shorter than the debounce: a spike
  AssertState(hexapod_v1_State_STATE_NORMAL, r.fs.output());

  const Output& out = r.Run(200, true);
  AssertState(hexapod_v1_State_STATE_TIPPED, out);
  TEST_ASSERT_FALSE(out.servos_enabled);

  r.sensors.roll_deg = 32.0f;  // below 35 but above the 30 release
  r.Stand();
  AssertState(hexapod_v1_State_STATE_TIPPED, r.fs.output());

  r.sensors.roll_deg = 0.0f;
  r.sensors.pitch_deg = -5.0f;
  r.Stand();
  AssertState(hexapod_v1_State_STATE_NORMAL, r.fs.output());
}

void test_blocked_direction_only() {
  Rig r;
  r.Stand();
  r.sensors.distances_mm[0] = 120;  // obstacle in front
  const Output& out = r.Run(40, true);
  AssertState(hexapod_v1_State_STATE_BLOCKED, out);
  TEST_ASSERT_EQUAL_HEX8(0x01, out.blocked_mask);
  TEST_ASSERT_TRUE(out.servos_enabled);

  float vx = 0.8f, vy = 0.3f;
  ClampVelocity(out.blocked_mask, &vx, &vy);
  TEST_ASSERT_EQUAL_FLOAT(0.0f, vx);  // forward blocked
  TEST_ASSERT_EQUAL_FLOAT(0.3f, vy);  // sideways still free
  vx = -0.8f;
  ClampVelocity(out.blocked_mask, &vx, &vy);
  TEST_ASSERT_EQUAL_FLOAT(-0.8f, vx);  // backing away is allowed

  r.sensors.distances_mm[0] = 180;  // between 150 and 200: hysteresis
  TEST_ASSERT_EQUAL_HEX8(0x01, r.Run(40, true).blocked_mask);
  r.sensors.distances_mm[0] = 250;
  const Output& clear = r.Run(40, true);
  TEST_ASSERT_EQUAL_HEX8(0x00, clear.blocked_mask);
  AssertState(hexapod_v1_State_STATE_NORMAL, clear);
}

void test_clamp_velocity_all_sides() {
  float vx = -1.0f, vy = -1.0f;
  ClampVelocity(0x2 | 0x4, &vx, &vy);  // right and rear
  TEST_ASSERT_EQUAL_FLOAT(0.0f, vx);
  TEST_ASSERT_EQUAL_FLOAT(0.0f, vy);
  vx = 1.0f;
  vy = 1.0f;
  ClampVelocity(0x8, &vx, &vy);  // left
  TEST_ASSERT_EQUAL_FLOAT(1.0f, vx);
  TEST_ASSERT_EQUAL_FLOAT(0.0f, vy);
}

void test_battery_low_reduces_speed() {
  Rig r;
  r.Stand();
  r.sensors.battery_voltage_v = 3.4f * config::kBatteryCells;
  r.Run(1000, true);  // sag shorter than the debounce
  TEST_ASSERT_EQUAL_FLOAT(1.0f, r.fs.output().speed_scale);

  const Output& out = r.Run(1200, true);
  AssertState(hexapod_v1_State_STATE_NORMAL, out);
  TEST_ASSERT_EQUAL_FLOAT(config::kLowBatterySpeedScale, out.speed_scale);
  TEST_ASSERT_TRUE(out.fault_flags & hexapod_v1_Fault_FAULT_BATTERY_LOW);

  r.sensors.battery_voltage_v = 3.55f * config::kBatteryCells;  // < 3.6
  TEST_ASSERT_EQUAL_FLOAT(config::kLowBatterySpeedScale,
                          r.Run(100, true).speed_scale);
  r.sensors.battery_voltage_v = 3.7f * config::kBatteryCells;
  TEST_ASSERT_EQUAL_FLOAT(1.0f, r.Run(100, true).speed_scale);
}

void test_battery_critical_sits_and_requests_shutdown() {
  Rig r;
  r.Stand();
  r.sensors.battery_voltage_v = 3.2f * config::kBatteryCells;
  const Output& out = r.Run(2100, true);
  AssertState(hexapod_v1_State_STATE_LOW_BATTERY, out);
  TEST_ASSERT_EQUAL_INT(Posture::kSit, out.posture);
  TEST_ASSERT_TRUE(out.request_shutdown);
  TEST_ASSERT_TRUE(out.fault_flags & hexapod_v1_Fault_FAULT_BATTERY_CRITICAL);

  r.Stand();  // refused while still critical
  AssertState(hexapod_v1_State_STATE_LOW_BATTERY, r.fs.output());

  // With the link gone for 10 s it also relaxes, to save the battery.
  r.Run(10100);
  AssertState(hexapod_v1_State_STATE_LOW_BATTERY, r.fs.output());
  TEST_ASSERT_FALSE(r.fs.output().servos_enabled);

  r.sensors.battery_voltage_v = 3.9f * config::kBatteryCells;  // charged
  r.Stand();
  AssertState(hexapod_v1_State_STATE_NORMAL, r.fs.output());
}

void test_overcurrent_after_3s_sits() {
  Rig r;
  r.Stand();
  r.sensors.current_a = config::kOvercurrentA + 1.0f;
  r.Run(2900, true);
  AssertState(hexapod_v1_State_STATE_NORMAL, r.fs.output());

  const Output& out = r.Run(200, true);
  AssertState(hexapod_v1_State_STATE_SAFE_SIT, out);
  TEST_ASSERT_EQUAL_INT(Posture::kSit, out.posture);
  TEST_ASSERT_TRUE(out.fault_flags & hexapod_v1_Fault_FAULT_OVERCURRENT);

  r.Stand();  // still high: stays
  AssertState(hexapod_v1_State_STATE_SAFE_SIT, r.fs.output());
  r.sensors.current_a = 2.0f;
  r.Stand();
  AssertState(hexapod_v1_State_STATE_NORMAL, r.fs.output());
}

void test_profile_change_only_while_seated() {
  Rig r;
  r.Tick();  // boot: relaxed, change allowed
  TEST_ASSERT_TRUE(
      r.fs.SetProfile(hexapod_v1_LinkProfile_LINK_PROFILE_CELLULAR));
  r.Stand();
  TEST_ASSERT_FALSE(r.fs.SetProfile(hexapod_v1_LinkProfile_LINK_PROFILE_WIFI));
  TEST_ASSERT_EQUAL_INT(hexapod_v1_LinkProfile_LINK_PROFILE_CELLULAR,
                        r.fs.profile());
  r.Run(1600);  // cellular SAFE_SIT
  TEST_ASSERT_TRUE(r.fs.SetProfile(hexapod_v1_LinkProfile_LINK_PROFILE_WIFI));
  TEST_ASSERT_FALSE(
      r.fs.SetProfile(hexapod_v1_LinkProfile_LINK_PROFILE_UNSPECIFIED));
}

void test_missing_sensors_raise_faults() {
  Rig r;
  r.sensors = SensorInputs();  // nothing connected (bench board)
  r.Stand();
  const uint32_t f = r.fs.output().fault_flags;
  TEST_ASSERT_TRUE(f & hexapod_v1_Fault_FAULT_IMU);
  TEST_ASSERT_TRUE(f & hexapod_v1_Fault_FAULT_POWER_MONITOR);
  TEST_ASSERT_TRUE(f & hexapod_v1_Fault_FAULT_DISTANCE_SENSOR);
  TEST_ASSERT_EQUAL_HEX8(0x00, r.fs.output().blocked_mask);
}

void test_estop_wins_over_everything() {
  Rig r;
  r.Stand();
  r.sensors.roll_deg = 50.0f;
  r.sensors.battery_voltage_v = 3.0f * config::kBatteryCells;
  r.Send(hexapod_v1_Mode_MODE_WALK, true);
  const Output& out = r.Run(2500);
  AssertState(hexapod_v1_State_STATE_ESTOP, out);
  TEST_ASSERT_FALSE(out.servos_enabled);
  TEST_ASSERT_EQUAL_FLOAT(0.0f, out.speed_scale);
}

int main() {
  UNITY_BEGIN();
  RUN_TEST(test_boot_is_relaxed_until_stand);
  RUN_TEST(test_steady_commands_stay_normal);
  RUN_TEST(test_wifi_link_loss_escalation);
  RUN_TEST(test_cellular_link_loss_thresholds);
  RUN_TEST(test_recovery_is_never_automatic);
  RUN_TEST(test_stand_recovers_from_safe_sit_and_relaxed);
  RUN_TEST(test_stale_or_repeated_seq_is_not_valid);
  RUN_TEST(test_estop_latches_even_with_stale_seq);
  RUN_TEST(test_tipped_relaxes_and_needs_level_to_recover);
  RUN_TEST(test_blocked_direction_only);
  RUN_TEST(test_clamp_velocity_all_sides);
  RUN_TEST(test_battery_low_reduces_speed);
  RUN_TEST(test_battery_critical_sits_and_requests_shutdown);
  RUN_TEST(test_overcurrent_after_3s_sits);
  RUN_TEST(test_profile_change_only_while_seated);
  RUN_TEST(test_missing_sensors_raise_faults);
  RUN_TEST(test_estop_wins_over_everything);
  return UNITY_END();
}
