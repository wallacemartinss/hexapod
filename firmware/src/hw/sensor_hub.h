// The I2C sensors on the sensor bus (I2C1): VL53L0X x4, BNO085, BME280 and
// INA226. Hardware side only; the conversions live in src/sensors/ and are
// tested natively.
//
// Every chip is found by its ID at boot and probed again while missing, so
// the firmware runs with any subset fitted. A missing or silent chip is
// never turned into a reading: its validity flag stays false and the
// failsafe reports the fault.
#pragma once

#include <stdint.h>

#include "safety/failsafe.h"
#include "sensors/bme280.h"
#include "sensors/orientation.h"

namespace hexapod {
namespace hw {

struct SensorSnapshot {
  safety::SensorInputs inputs;  // what the failsafe uses
  sensors::Orientation orientation;
  float current_a = 0;  // always reported; trusted only per inputs
  bool env_valid = false;
  sensors::EnvReading env;
  uint32_t updated_ms = 0;  // last Poll
};

// Owned by the sensors task alone (I2C1 is not shared).
class SensorHub {
 public:
  void Begin(uint32_t now_ms);
  // One 20 Hz cycle: reads what is due, retries one missing chip.
  void Poll(uint32_t now_ms);
  const SensorSnapshot& snapshot() const { return snap_; }

 private:
  void Retry(uint32_t now_ms);
  void PollDistances(uint32_t now_ms);
  void PollImu(uint32_t now_ms);
  void PollPower();
  void PollEnv(uint32_t now_ms);

  SensorSnapshot snap_;
  uint32_t next_retry_ms_ = 0;
  uint32_t next_env_ms_ = 0;
  uint32_t imu_ok_ms_ = 0;
  bool imu_seen_ = false;
  int retry_turn_ = 0;
};

}  // namespace hw
}  // namespace hexapod
