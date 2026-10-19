#include "hw/sensor_hub.h"

#include <Adafruit_BNO08x.h>
#include <Arduino.h>
#include <VL53L0X.h>
#include <Wire.h>

#include "config.h"
#include "pins.h"
#include "sensors/distance.h"
#include "sensors/power.h"

namespace hexapod {
namespace hw {
namespace {

TwoWire& Bus() { return Wire1; }

// --- Raw register access (BME280 and INA226) ---

bool ReadRegs(uint8_t addr, uint8_t reg, uint8_t* out, size_t n) {
  Bus().beginTransmission(addr);
  Bus().write(reg);
  if (Bus().endTransmission(false) != 0) return false;
  if (Bus().requestFrom(addr, static_cast<uint8_t>(n)) != n) return false;
  for (size_t i = 0; i < n; ++i) out[i] = Bus().read();
  return true;
}

bool WriteReg8(uint8_t addr, uint8_t reg, uint8_t value) {
  Bus().beginTransmission(addr);
  Bus().write(reg);
  Bus().write(value);
  return Bus().endTransmission() == 0;
}

bool WriteReg16(uint8_t addr, uint8_t reg, uint16_t value) {
  Bus().beginTransmission(addr);
  Bus().write(reg);
  Bus().write(value >> 8);
  Bus().write(value & 0xFF);
  return Bus().endTransmission() == 0;
}

bool ReadReg16(uint8_t addr, uint8_t reg, uint16_t* value) {
  uint8_t b[2];
  if (!ReadRegs(addr, reg, b, 2)) return false;
  *value = (b[0] << 8) | b[1];  // the INA226 is big-endian
  return true;
}

// --- BME280 ---

bool g_env_up = false;
sensors::Bme280Calib g_env_calib;

bool EnvInit() {
  uint8_t id = 0;
  if (!ReadRegs(i2c::kBme280, 0xD0, &id, 1) || id != 0x60) return false;
  if (!WriteReg8(i2c::kBme280, 0xE0, 0xB6)) return false;  // soft reset
  delay(3);
  uint8_t tp[26], h[7];
  if (!ReadRegs(i2c::kBme280, 0x88, tp, sizeof(tp)) ||
      !ReadRegs(i2c::kBme280, 0xE1, h, sizeof(h))) {
    return false;
  }
  g_env_calib = sensors::ParseBme280Calib(tp, h);
  // Humidity x1 (must precede ctrl_meas), 1 s standby + IIR filter 4,
  // temperature and pressure x1, normal mode.
  return WriteReg8(i2c::kBme280, 0xF2, 0x01) &&
         WriteReg8(i2c::kBme280, 0xF5, (0b101 << 5) | (0b010 << 2)) &&
         WriteReg8(i2c::kBme280, 0xF4, 0x27);
}

// --- INA226 ---

bool g_power_up = false;

bool PowerInit() {
  uint16_t id = 0;
  if (!ReadReg16(i2c::kIna226, 0xFE, &id) ||
      id != sensors::kIna226ManufacturerId) {
    return false;
  }
  return WriteReg16(i2c::kIna226, 0x00, sensors::kIna226Config);
}

// --- VL53L0X: all start at 0x29; XSHUT brings them up one at a time ---

VL53L0X g_tof[4];
sensors::DistanceFilter g_dist[4];
bool g_tof_up[4] = {};
uint32_t g_tof_heard_ms[4] = {};  // init or last good reading

bool TofInit(int i, uint32_t now_ms) {
  pinMode(pins::kXshut[i], OUTPUT);
  digitalWrite(pins::kXshut[i], HIGH);  // only this one answers at 0x29
  delay(2);                             // boot time, 1.2 ms max
  VL53L0X& t = g_tof[i];
  t.setBus(&Bus());
  t.setAddress(i2c::kVl53l0xDefault);
  t.setTimeout(config::kDistanceTimeoutMs);
  if (!t.init()) {
    digitalWrite(pins::kXshut[i], LOW);  // keep 0x29 free for the next try
    return false;
  }
  t.setAddress(i2c::kVl53l0x[i]);
  t.startContinuous();
  g_dist[i] = sensors::DistanceFilter();
  g_tof_heard_ms[i] = now_ms;
  return true;
}

// --- BNO085 ---

Adafruit_BNO08x g_imu(pins::kImuReset);
bool g_imu_up = false;

bool ImuInit() {
  if (!g_imu.begin_I2C(i2c::kBno085, &Bus())) return false;
  return g_imu.enableReport(SH2_GAME_ROTATION_VECTOR, config::kImuReportUs);
}

}  // namespace

void SensorHub::Begin(uint32_t now_ms) {
  for (int i = 0; i < 4; ++i) {  // every VL53L0X off before the bus starts
    pinMode(pins::kXshut[i], OUTPUT);
    digitalWrite(pins::kXshut[i], LOW);
  }
  Bus().begin(pins::kSensorSda, pins::kSensorScl, config::kSensorBusHz);
  Bus().setTimeOut(10);  // ms: a stuck chip must not stall the task
  delay(2);
  for (int i = 0; i < 4; ++i) g_tof_up[i] = TofInit(i, now_ms);
  g_imu_up = ImuInit();
  g_env_up = EnvInit();
  g_power_up = PowerInit();
  next_retry_ms_ = now_ms + config::kSensorRetryMs;
}

void SensorHub::Retry(uint32_t now_ms) {
  if (static_cast<int32_t>(now_ms - next_retry_ms_) < 0) return;
  next_retry_ms_ = now_ms + config::kSensorRetryMs;
  // One chip per round keeps a cycle short.
  for (int n = 0; n < 7; ++n) {
    const int turn = retry_turn_;
    retry_turn_ = (retry_turn_ + 1) % 7;
    if (turn < 4 && !g_tof_up[turn]) {
      g_tof_up[turn] = TofInit(turn, now_ms);
      return;
    }
    if (turn == 4 && !g_imu_up) {
      g_imu_up = ImuInit();
      return;
    }
    if (turn == 5 && !g_env_up) {
      g_env_up = EnvInit();
      return;
    }
    if (turn == 6 && !g_power_up) {
      g_power_up = PowerInit();
      return;
    }
  }
}

void SensorHub::PollDistances(uint32_t now_ms) {
  uint8_t valid = 0;
  for (int i = 0; i < 4; ++i) {
    if (g_tof_up[i]) {
      VL53L0X& t = g_tof[i];
      // Non-blocking: read only a finished measurement.
      const uint8_t status = t.readReg(VL53L0X::RESULT_INTERRUPT_STATUS);
      if (t.last_status == 0 && (status & 0x07) != 0) {
        const uint16_t mm = t.readRangeContinuousMillimeters();
        g_dist[i].Update(mm, t.timeoutOccurred() || t.last_status != 0, now_ms);
      }
      if (g_dist[i].valid(now_ms)) g_tof_heard_ms[i] = now_ms;
      if (now_ms - g_tof_heard_ms[i] > config::kSensorStaleMs) {
        // Silent for too long: off, and back in the retry round.
        g_tof_up[i] = false;
        digitalWrite(pins::kXshut[i], LOW);
      }
    }
    if (g_tof_up[i] && g_dist[i].valid(now_ms)) {
      valid |= 1u << i;
      snap_.inputs.distances_mm[i] = g_dist[i].mm();
    } else {
      snap_.inputs.distances_mm[i] = 0;
    }
  }
  snap_.inputs.distances_valid_mask = valid;
}

void SensorHub::PollImu(uint32_t now_ms) {
  if (g_imu_up) {
    if (g_imu.wasReset()) {  // the chip rebooted: reports are off again
      g_imu.enableReport(SH2_GAME_ROTATION_VECTOR, config::kImuReportUs);
    }
    sh2_SensorValue_t v;
    for (int n = 0; n < 8 && g_imu.getSensorEvent(&v); ++n) {
      if (v.sensorId != SH2_GAME_ROTATION_VECTOR) continue;
      const auto& r = v.un.gameRotationVector;
      snap_.orientation = sensors::ToOrientation({r.real, r.i, r.j, r.k});
      imu_ok_ms_ = now_ms;
      imu_seen_ = true;
    }
    if (imu_seen_ && now_ms - imu_ok_ms_ > config::kSensorStaleMs) {
      g_imu_up = imu_seen_ = false;  // silent: probe it again later
    }
  }
  snap_.inputs.imu_valid =
      g_imu_up && imu_seen_ && now_ms - imu_ok_ms_ <= config::kSensorStaleMs;
  snap_.inputs.roll_deg =
      snap_.inputs.imu_valid ? snap_.orientation.roll_deg : 0;
  snap_.inputs.pitch_deg =
      snap_.inputs.imu_valid ? snap_.orientation.pitch_deg : 0;
}

void SensorHub::PollPower() {
  uint16_t shunt = 0, bus = 0;
  if (g_power_up && !(ReadReg16(i2c::kIna226, 0x01, &shunt) &&
                      ReadReg16(i2c::kIna226, 0x02, &bus))) {
    g_power_up = false;
  }
  const sensors::PowerReading p = sensors::ConvertIna226(
      static_cast<int16_t>(shunt), bus, config::kShuntOhm);
  snap_.inputs.battery_valid = g_power_up;
  snap_.inputs.battery_voltage_v = g_power_up ? p.voltage_v : 0;
  snap_.current_a = g_power_up ? p.current_a : 0;
  snap_.inputs.current_valid =
      g_power_up && config::kShuntConfirmed && !p.current_saturated;
  snap_.inputs.current_a = snap_.inputs.current_valid ? p.current_a : 0;
}

void SensorHub::PollEnv(uint32_t now_ms) {
  if (static_cast<int32_t>(now_ms - next_env_ms_) < 0) return;
  next_env_ms_ = now_ms + config::kEnvPeriodMs;
  uint8_t b[8];
  if (g_env_up && !ReadRegs(i2c::kBme280, 0xF7, b, sizeof(b))) g_env_up = false;
  if (!g_env_up) {
    snap_.env_valid = false;
    return;
  }
  const int32_t adc_p = (b[0] << 12) | (b[1] << 4) | (b[2] >> 4);
  const int32_t adc_t = (b[3] << 12) | (b[4] << 4) | (b[5] >> 4);
  const int32_t adc_h = (b[6] << 8) | b[7];
  if (adc_t == 0x80000) return;  // first conversion not done yet
  snap_.env = sensors::CompensateBme280(g_env_calib, adc_t, adc_p, adc_h);
  snap_.env_valid = true;
}

void SensorHub::Poll(uint32_t now_ms) {
  PollImu(now_ms);
  PollDistances(now_ms);
  PollPower();
  PollEnv(now_ms);
  Retry(now_ms);
  snap_.updated_ms = now_ms;
}

}  // namespace hw
}  // namespace hexapod
