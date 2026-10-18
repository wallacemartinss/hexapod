// Physical and timing constants of the hexapod firmware, in one place.
// Every value carries its unit in the comment.
#pragma once

#include <stdint.h>

namespace hexapod {
namespace config {

// --- Link (USB serial to the Pi) ---
// Wire contract version; see proto/README.md. Bump with any incompatible
// change.
constexpr uint32_t kProtocolVersion = 1;
// bit/s. Used by the CP2102 of the bench board; ignored by the S3 native USB.
constexpr uint32_t kLinkBaud = 115200;
constexpr uint32_t kLinkRxBufferSize = 1024;  // bytes
constexpr uint32_t kTelemetryPeriodMs = 100;  // ms (10 Hz)
constexpr uint32_t kLinkPollPeriodMs = 2;     // ms between serial reads

// --- Milestone guard ---
// While false, PCA9685 OE is held HIGH no matter what the failsafe allows.
// Only set true together with the servo driver, after the user's go-ahead.
constexpr bool kServoOutputsAllowed = false;

// --- Failsafe (CLAUDE.md section 6) ---
struct LinkTimeouts {
  uint32_t stop_ms;   // ms without a valid command -> STOPPING
  uint32_t sit_ms;    // ms without a valid command -> SAFE_SIT
  uint32_t relax_ms;  // ms without a valid command -> RELAXED
};
constexpr LinkTimeouts kWifiTimeouts = {150, 500, 10000};
constexpr LinkTimeouts kCellularTimeouts = {400, 1500, 10000};
constexpr uint32_t kStopRampMs = 300;  // ms to decelerate to zero

constexpr float kTippedDeg = 35.0f;          // deg of roll or pitch -> TIPPED
constexpr float kTippedReleaseDeg = 30.0f;   // deg, needed before recovery
constexpr uint32_t kTippedDebounceMs = 100;  // ms above kTippedDeg

constexpr uint16_t kBlockDistanceMm = 150;  // mm -> direction blocked
constexpr uint16_t kBlockReleaseMm = 200;   // mm -> direction free again

constexpr int kBatteryCells = 3;          // LiPo 3S
constexpr float kCellLowV = 3.5f;         // V/cell -> reduced speed
constexpr float kCellCriticalV = 3.3f;    // V/cell -> LOW_BATTERY
constexpr float kCellHysteresisV = 0.1f;  // V/cell to clear a battery level
constexpr uint32_t kBatteryDebounceMs = 2000;  // ms below a level (load sag)
constexpr float kLowBatterySpeedScale = 0.5f;  // speed multiplier when low

// TODO(hardware): tune with real consumption; only trusted with the right
// INA226 shunt (CLAUDE.md section 9).
constexpr float kOvercurrentA = 12.0f;     // A
constexpr uint32_t kOvercurrentMs = 3000;  // ms above kOvercurrentA

// --- FreeRTOS tasks ---
constexpr uint32_t kMotionPeriodMs = 20;     // ms (50 Hz)
constexpr uint32_t kMotionTaskStack = 4096;  // bytes
constexpr uint32_t kMotionTaskPriority = 5;
constexpr int kMotionTaskCore = 1;
constexpr uint32_t kLinkTaskStack = 6144;  // bytes
constexpr uint32_t kLinkTaskPriority = 3;
constexpr int kLinkTaskCore = 0;
constexpr uint32_t kLinkQueueLength = 8;  // pending commands/configs
// Task watchdog: a stuck task resets the chip (OE pull-up keeps servos off).
constexpr uint32_t kTaskWatchdogS = 1;  // s (IDF 4.4 takes whole seconds)

}  // namespace config
}  // namespace hexapod
