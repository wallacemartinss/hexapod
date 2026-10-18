#include "safety/failsafe.h"

#include <math.h>

namespace hexapod {
namespace safety {
namespace {

// True once `condition` has held for `hold_ms` without interruption.
bool Debounced(bool condition, bool* streak, uint32_t* since, uint32_t now_ms,
               uint32_t hold_ms) {
  if (!condition) {
    *streak = false;
    return false;
  }
  if (!*streak) {
    *streak = true;
    *since = now_ms;
  }
  return now_ms - *since >= hold_ms;
}

float Tilt(const SensorInputs& s) {
  return fmaxf(fabsf(s.roll_deg), fabsf(s.pitch_deg));
}

float CellVoltage(const SensorInputs& s) {
  return s.battery_voltage_v / config::kBatteryCells;
}

void Raise(Posture* posture, Posture at_least) {
  if (at_least > *posture) *posture = at_least;
}

}  // namespace

Failsafe::Failsafe(hexapod_v1_LinkProfile profile)
    : profile_(profile == hexapod_v1_LinkProfile_LINK_PROFILE_CELLULAR
                   ? profile
                   : hexapod_v1_LinkProfile_LINK_PROFILE_WIFI) {}

bool Failsafe::OnCommand(const CommandInput& command, uint32_t now_ms) {
  const bool valid = command.seq > last_seq_;
  if (valid) {
    last_seq_ = command.seq;
    last_valid_ms_ = now_ms;
    has_command_ = true;
  }
  if (command.estop) {
    estop_ = true;
    pending_stand_ = false;
  } else if (valid && command.mode == hexapod_v1_Mode_MODE_STAND) {
    pending_stand_ = true;
  }
  return valid;
}

bool Failsafe::SetProfile(hexapod_v1_LinkProfile profile) {
  if (output_.posture < Posture::kSit) return false;
  if (profile != hexapod_v1_LinkProfile_LINK_PROFILE_WIFI &&
      profile != hexapod_v1_LinkProfile_LINK_PROFILE_CELLULAR) {
    return false;
  }
  profile_ = profile;
  return true;
}

const config::LinkTimeouts& Failsafe::timeouts() const {
  return profile_ == hexapod_v1_LinkProfile_LINK_PROFILE_CELLULAR
             ? config::kCellularTimeouts
             : config::kWifiTimeouts;
}

Failsafe::LinkStage Failsafe::StageFor(uint32_t silence_ms) const {
  const config::LinkTimeouts& t = timeouts();
  if (silence_ms > t.relax_ms) return LinkStage::kRelaxed;
  if (silence_ms > t.sit_ms) return LinkStage::kSafeSit;
  if (silence_ms > t.stop_ms) return LinkStage::kStopping;
  return LinkStage::kOk;
}

void Failsafe::TryRecover(const SensorInputs& s) {
  latched_stage_ = LinkStage::kOk;  // the STAND command proves the link is up
  estop_ = false;
  if (tipped_ && s.imu_valid && Tilt(s) <= config::kTippedReleaseDeg) {
    tipped_ = false;
  }
  if (battery_critical_ && s.battery_valid &&
      CellVoltage(s) >= config::kCellCriticalV + config::kCellHysteresisV) {
    battery_critical_ = false;
  }
  if (overcurrent_ &&
      !(s.current_valid && s.current_a > config::kOvercurrentA)) {
    overcurrent_ = false;
  }
}

void Failsafe::UpdateBlocked(const SensorInputs& s) {
  for (int i = 0; i < 4; ++i) {
    const uint8_t bit = static_cast<uint8_t>(1u << i);
    if (!(s.distances_valid_mask & bit) ||
        s.distances_mm[i] > config::kBlockReleaseMm) {
      blocked_mask_ &= static_cast<uint8_t>(~bit);
    } else if (s.distances_mm[i] < config::kBlockDistanceMm) {
      blocked_mask_ |= bit;
    }
  }
}

const Output& Failsafe::Update(const SensorInputs& s, uint32_t now_ms) {
  // 1. Conditions from sensors (latching ones only set here).
  if (Debounced(s.imu_valid && Tilt(s) > config::kTippedDeg, &tilt_high_,
                &tilt_high_since_, now_ms, config::kTippedDebounceMs)) {
    tipped_ = true;
  }
  if (s.battery_valid) {
    const float cell = CellVoltage(s);
    if (Debounced(cell < config::kCellCriticalV, &cell_critical_,
                  &cell_critical_since_, now_ms, config::kBatteryDebounceMs)) {
      battery_critical_ = true;
    }
    if (Debounced(cell < config::kCellLowV, &cell_low_, &cell_low_since_,
                  now_ms, config::kBatteryDebounceMs)) {
      battery_low_ = true;
    } else if (cell >= config::kCellLowV + config::kCellHysteresisV) {
      battery_low_ = false;
    }
  } else {
    cell_low_ = cell_critical_ = false;
  }
  if (Debounced(s.current_valid && s.current_a > config::kOvercurrentA,
                &current_high_, &current_high_since_, now_ms,
                config::kOvercurrentMs)) {
    overcurrent_ = true;
  }
  UpdateBlocked(s);

  // 2. Recovery, only on request and only for causes that are gone.
  if (pending_stand_) {
    pending_stand_ = false;
    TryRecover(s);
  }

  // 3. Link loss: escalate with silence, never de-escalate on its own.
  const LinkStage stage =
      has_command_ ? StageFor(now_ms - last_valid_ms_) : LinkStage::kRelaxed;
  if (stage > latched_stage_) {
    if (latched_stage_ < LinkStage::kStopping) stop_entered_ms_ = now_ms;
    latched_stage_ = stage;
  }

  // 4. Posture: the most restrictive of all active causes.
  Posture posture = Posture::kFollow;
  switch (latched_stage_) {
    case LinkStage::kOk:
      break;
    case LinkStage::kStopping:
      Raise(&posture, Posture::kStop);
      break;
    case LinkStage::kSafeSit:
      Raise(&posture, Posture::kSit);
      break;
    case LinkStage::kRelaxed:
      Raise(&posture, Posture::kRelax);
      break;
  }
  if (battery_critical_ || overcurrent_) Raise(&posture, Posture::kSit);
  if (estop_ || tipped_) Raise(&posture, Posture::kRelax);

  // 5. Reported state, by priority.
  hexapod_v1_State state = hexapod_v1_State_STATE_NORMAL;
  if (estop_) {
    state = hexapod_v1_State_STATE_ESTOP;
  } else if (tipped_) {
    state = hexapod_v1_State_STATE_TIPPED;
  } else if (battery_critical_) {
    state = hexapod_v1_State_STATE_LOW_BATTERY;
  } else if (latched_stage_ == LinkStage::kRelaxed) {
    state = hexapod_v1_State_STATE_RELAXED;
  } else if (latched_stage_ == LinkStage::kSafeSit || overcurrent_) {
    state = hexapod_v1_State_STATE_SAFE_SIT;
  } else if (latched_stage_ == LinkStage::kStopping) {
    state = hexapod_v1_State_STATE_STOPPING;
  } else if (blocked_mask_ != 0) {
    state = hexapod_v1_State_STATE_BLOCKED;
  }

  const float battery_factor =
      battery_low_ ? config::kLowBatterySpeedScale : 1.0f;
  float speed_scale = 0.0f;
  if (posture == Posture::kFollow) {
    speed_scale = battery_factor;
  } else if (posture == Posture::kStop) {
    const float ramp = 1.0f - static_cast<float>(now_ms - stop_entered_ms_) /
                                  static_cast<float>(config::kStopRampMs);
    speed_scale = fmaxf(0.0f, ramp) * battery_factor;
  }

  uint32_t faults = 0;
  if (!s.imu_valid) faults |= hexapod_v1_Fault_FAULT_IMU;
  if (!s.battery_valid) faults |= hexapod_v1_Fault_FAULT_POWER_MONITOR;
  if (s.distances_valid_mask != 0x0F) {
    faults |= hexapod_v1_Fault_FAULT_DISTANCE_SENSOR;
  }
  if (battery_low_) faults |= hexapod_v1_Fault_FAULT_BATTERY_LOW;
  if (battery_critical_) faults |= hexapod_v1_Fault_FAULT_BATTERY_CRITICAL;
  if (overcurrent_) faults |= hexapod_v1_Fault_FAULT_OVERCURRENT;

  output_.state = state;
  output_.posture = posture;
  output_.servos_enabled = posture != Posture::kRelax;
  output_.speed_scale = speed_scale;
  output_.blocked_mask = blocked_mask_;
  output_.fault_flags = faults;
  output_.request_shutdown = battery_critical_;
  return output_;
}

void ClampVelocity(uint8_t blocked_mask, float* vx, float* vy) {
  if ((blocked_mask & 0x1) && *vx > 0.0f) *vx = 0.0f;  // front
  if ((blocked_mask & 0x2) && *vy < 0.0f) *vy = 0.0f;  // right
  if ((blocked_mask & 0x4) && *vx < 0.0f) *vx = 0.0f;  // rear
  if ((blocked_mask & 0x8) && *vy > 0.0f) *vy = 0.0f;  // left
}

}  // namespace safety
}  // namespace hexapod
