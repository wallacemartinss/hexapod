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

// --- Leg geometry (measured from the STLs by cad/measure_legs.py) ---
// Conventions in cad/README.md: body x forward, y left, z up; z = 0 is the
// plane of the femur axes.
constexpr float kCoxaMm = 38.07f;    // coxa axis -> femur axis
constexpr float kFemurMm = 86.27f;   // femur axis -> knee axis
constexpr float kTibiaMm = 163.02f;  // knee axis -> foot tip
// Angle between the tibia bracket axis and the knee->foot line. Used when
// mapping the tibia joint angle to its servo (servo/ module).
constexpr float kTibiaFootOffsetDeg = 18.54f;  // deg

struct LegMount {
  float x_mm;  // coxa axis position in the body frame
  float y_mm;
  float angle_deg;  // outward direction of the leg at coxa angle 0
};
// Leg order: 0 front-left, 1 middle-left, 2 rear-left, 3 front-right,
// 4 middle-right, 5 rear-right. TODO(hardware): confirm front = +x.
constexpr LegMount kLegMounts[6] = {
    {100.99f, 57.15f, 30.0f},   {0.0f, 105.78f, 90.0f},
    {-100.98f, 57.16f, 150.0f}, {100.99f, -57.08f, -30.0f},
    {0.0f, -105.67f, -90.0f},   {-100.98f, -57.07f, -150.0f},
};

// IK joint limits, before servo calibration (deg). TODO(hardware): narrow to
// the real collision-free range; per-servo limits will also live in NVS.
constexpr float kCoxaMinDeg = -45.0f;
constexpr float kCoxaMaxDeg = 45.0f;
constexpr float kFemurMinDeg = -80.0f;
constexpr float kFemurMaxDeg = 100.0f;
constexpr float kTibiaMinDeg = -165.0f;
constexpr float kTibiaMaxDeg = 15.0f;

// --- Body pose and gait ---
// Foot distance from its coxa axis when standing (mm).
constexpr float kNeutralReachMm = 160.0f;
// Body height = femur axis plane above the ground (mm). Command.body_height
// 0..1 maps to min..max. The coxa bracket hangs 20 mm below the femur axis.
constexpr float kBodyHeightMinMm =
    80.0f;  // lower needs femur > 100 deg in swing
constexpr float kBodyHeightMaxMm = 130.0f;
constexpr float kSitHeightMm = 25.0f;  // body resting on the ground
constexpr float kSitReachMm = 180.0f;  // feet spread out when sitting
constexpr float kMaxBodyRollDeg = 15.0f;
constexpr float kMaxBodyPitchDeg = 15.0f;
constexpr float kMaxBodyYawDeg = 15.0f;

constexpr float kMaxSpeedMmS = 80.0f;      // Command.vx/vy = 1 -> mm/s
constexpr float kMaxYawRateDegS = 20.0f;   // Command.yaw_rate = 1 -> deg/s
constexpr float kGaitPeriodS = 1.0f;       // s per full tripod cycle
constexpr float kStepHeightMm = 30.0f;     // foot lift in swing
constexpr float kMaxHalfStrideMm = 35.0f;  // max foot travel from neutral
// --- Front legs mode (MODE_FRONT_LEGS) ---
// Body moves back by this before the front legs leave the ground, so the
// centre of mass sits over the 4 remaining feet. TODO(hardware): check the
// real balance on the robot.
constexpr float kFrontLegsShiftMm = 50.0f;  // mm
// Raised paw pose (front leg frame): reach from the coxa axis, height above
// the femur axis plane. Command.front_legs moves it by +-range. Stretched
// forward on purpose: closer to the body the knee-up IK needs the femur
// beyond its 100 deg limit. 12.6 deg of joint margin over the whole range.
constexpr float kPawRestReachMm = 235.0f;  // mm
constexpr float kPawRestZMm = 40.0f;       // mm
constexpr float kPawReachRangeMm = 30.0f;  // mm
constexpr float kPawLiftRangeMm = 50.0f;   // mm
// A paw first rises straight up by this, so it never drags on the ground.
constexpr float kPawHoverMm = 40.0f;  // mm
// Feet move in straight lines (Cartesian), never along joint-space arcs that
// would lift a sliding foot or drag a paw.
constexpr float kBodyShiftSpeedMmS = 60.0f;  // mm/s, all feet sliding
constexpr float kPawSpeedMmS = 150.0f;       // mm/s, paws in the air
// A phase ends when every joint is within this of its target.
constexpr float kSettledDeg = 0.5f;  // deg

// Joint speed limit: every target is approached at most this fast.
constexpr float kMaxJointSpeedDegS = 180.0f;  // deg/s

// --- MQ-2 smoke/gas sensor (informative: never moves the robot) ---
// Not fitted yet: telemetry reports FAULT_GAS_SENSOR until this is true.
constexpr bool kGasSensorFitted = false;
// The heater needs a few minutes after power-up (24-48 h the very first time)
// before readings settle; until then the level is not trusted.
constexpr uint32_t kGasWarmupMs = 180000;  // ms
// Clean-air baseline: slow average of the level while there is no alarm.
constexpr float kGasBaselineAlpha = 0.01f;  // per sample (10 Hz: ~10 s)
// Alarm when the level rises this far above the baseline; clears below
// kGasAlarmRisePct - kGasAlarmHysteresisPct.
constexpr float kGasAlarmRisePct = 15.0f;       // percentage points
constexpr float kGasAlarmHysteresisPct = 5.0f;  // percentage points
// AO swings up to 5 V: a 10k/15k divider brings it to ~3.0 V at the ADC.
constexpr float kGasAdcFullScale = 4095.0f;  // counts (12-bit)

// --- I2C sensors (sensor bus, I2C1) ---
// Each chip is detected at boot by its ID and retried while missing; an
// absent one is reported in fault_flags and never fakes a reading.
constexpr uint32_t kSensorBusHz = 400000;  // Hz
constexpr uint32_t kSensorPeriodMs = 50;   // ms (20 Hz sensors task)
constexpr uint32_t kSensorRetryMs =
    5000;  // ms between probes of a missing chip
constexpr uint32_t kSensorStaleMs =
    500;  // ms without a fresh reading -> invalid
constexpr uint32_t kEnvPeriodMs = 1000;  // ms between BME280 readings

// VL53L0X: continuous ranging; past this the reading means "nothing near".
constexpr uint16_t kDistanceMaxMm = 2000;    // mm
constexpr uint16_t kDistanceTimeoutMs = 60;  // ms waiting for one reading

// INA226 shunt. TODO(hardware): the module's stock 0.1 ohm (R100) only
// measures up to ~0.8 A; swap it for 2 mohm (CLAUDE.md section 9), then set
// kShuntConfirmed. Until then the current goes to telemetry but the
// failsafe's overcurrent check ignores it. The voltage is right either way.
constexpr float kShuntOhm = 0.002f;  // ohm
constexpr bool kShuntConfirmed = false;

// BNO085 mounting: roll and pitch read when the body is level.
// TODO(hardware): measure on the robot standing on a flat floor.
constexpr float kImuRollOffsetDeg = 0.0f;   // deg
constexpr float kImuPitchOffsetDeg = 0.0f;  // deg
constexpr uint32_t kImuReportUs = 20000;  // us between rotation vectors (50 Hz)

// --- FreeRTOS tasks ---
constexpr uint32_t kMotionPeriodMs = 20;     // ms (50 Hz)
constexpr uint32_t kMotionTaskStack = 4096;  // bytes
constexpr uint32_t kMotionTaskPriority = 5;
constexpr int kMotionTaskCore = 1;
constexpr uint32_t kLinkTaskStack = 6144;  // bytes
constexpr uint32_t kLinkTaskPriority = 3;
constexpr int kLinkTaskCore = 0;
constexpr uint32_t kLinkQueueLength = 8;     // pending commands/configs
constexpr uint32_t kSensorTaskStack = 4096;  // bytes
constexpr uint32_t kSensorTaskPriority = 2;
constexpr int kSensorTaskCore = 0;
// Task watchdog: a stuck task resets the chip (OE pull-up keeps servos off).
constexpr uint32_t kTaskWatchdogS = 1;  // s (IDF 4.4 takes whole seconds)

}  // namespace config
}  // namespace hexapod
