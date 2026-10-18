// Failsafe state machine (CLAUDE.md section 6). Pure logic: no Arduino, no
// FreeRTOS. The motion task feeds it every 50 Hz cycle and obeys its Output.
//
// It cannot be disabled by any message: the only remote influence is a valid
// Command with mode = STAND, which clears latched states whose cause is gone.
#pragma once

#include <stdint.h>

#include "config.h"
#include "hexapod/v1/common.pb.h"
#include "hexapod/v1/telemetry.pb.h"

namespace hexapod {
namespace safety {

// What the legs may do, from least to most restrictive.
enum class Posture : uint8_t {
  kFollow,  // obey the command (speed scaled, blocked directions zeroed)
  kStop,    // decelerate to zero and stand still
  kSit,     // finish the step, feet down, lower the body
  kRelax,   // no torque: PCA9685 OE high
};

struct SensorInputs {
  bool imu_valid = false;
  float roll_deg = 0.0f;
  float pitch_deg = 0.0f;
  bool battery_valid = false;
  float battery_voltage_v = 0.0f;  // whole pack
  bool current_valid = false;
  float current_a = 0.0f;
  uint8_t distances_valid_mask = 0;  // bit i: distances_mm[i] is valid
  uint16_t distances_mm[4] = {};     // front, right, rear, left
};

struct CommandInput {
  uint32_t seq = 0;
  hexapod_v1_Mode mode = hexapod_v1_Mode_MODE_UNSPECIFIED;
  bool estop = false;
};

struct Output {
  hexapod_v1_State state = hexapod_v1_State_STATE_RELAXED;
  Posture posture = Posture::kRelax;
  bool servos_enabled = false;
  float speed_scale = 0.0f;       // multiply vx, vy and yaw_rate by this
  uint8_t blocked_mask = 0;       // bit i: no motion towards distances_mm[i]
  uint32_t fault_flags = 0;       // OR of hexapod_v1_Fault
  bool request_shutdown = false;  // battery critical: ask the Pi to power off
};

class Failsafe {
 public:
  explicit Failsafe(hexapod_v1_LinkProfile profile =
                        hexapod_v1_LinkProfile_LINK_PROFILE_WIFI);

  // Feeds a decoded Command. Returns true if it is valid (seq newer than the
  // last accepted). estop latches ESTOP even when the seq is stale.
  bool OnCommand(const CommandInput& command, uint32_t now_ms);

  // Switches the timeout profile. Only accepted while seated or relaxed.
  bool SetProfile(hexapod_v1_LinkProfile profile);

  // Runs one cycle. Call at 50 Hz.
  const Output& Update(const SensorInputs& sensors, uint32_t now_ms);

  const Output& output() const { return output_; }
  uint32_t last_command_seq() const { return last_seq_; }
  hexapod_v1_LinkProfile profile() const { return profile_; }

 private:
  enum class LinkStage : uint8_t { kOk, kStopping, kSafeSit, kRelaxed };

  const config::LinkTimeouts& timeouts() const;
  LinkStage StageFor(uint32_t silence_ms) const;
  void TryRecover(const SensorInputs& sensors);
  void UpdateBlocked(const SensorInputs& sensors);

  hexapod_v1_LinkProfile profile_;
  bool has_command_ = false;
  uint32_t last_seq_ = 0;
  uint32_t last_valid_ms_ = 0;
  bool pending_stand_ = false;

  // Latched until a STAND command finds the cause gone. Boot = relaxed.
  LinkStage latched_stage_ = LinkStage::kRelaxed;
  uint32_t stop_entered_ms_ = 0;
  bool estop_ = false;
  bool tipped_ = false;
  bool battery_critical_ = false;
  bool overcurrent_ = false;

  // Not latched.
  bool battery_low_ = false;
  uint8_t blocked_mask_ = 0;

  // Debounce timers: start of the current "condition true" streak.
  bool tilt_high_ = false;
  uint32_t tilt_high_since_ = 0;
  bool cell_low_ = false;
  uint32_t cell_low_since_ = 0;
  bool cell_critical_ = false;
  uint32_t cell_critical_since_ = 0;
  bool current_high_ = false;
  uint32_t current_high_since_ = 0;

  Output output_;
};

// Zeroes the velocity components pointing at a blocked sensor.
// Axes: vx forward(+), vy left(+); sensors front, right, rear, left.
void ClampVelocity(uint8_t blocked_mask, float* vx, float* vy);

}  // namespace safety
}  // namespace hexapod
