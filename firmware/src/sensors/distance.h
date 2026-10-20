// VL53L0X readings -> what the failsafe sees. Pure logic: no Arduino.
//
// Nothing in range is a valid reading ("far"), not a fault: the failsafe
// only blocks a direction for something close. A sensor that stops
// answering, or answers too late, is invalid (FAULT_DISTANCE_SENSOR).
#pragma once

#include <stdint.h>

namespace hexapod {
namespace sensors {

class DistanceFilter {
 public:
  // One reading from the sensor at now_ms: range in mm as the chip gives it
  // (8190/8191 or more = nothing in range), timeout = no answer.
  void Update(uint16_t raw_mm, bool timeout, uint32_t now_ms);
  // Valid when the last good reading is recent.
  bool valid(uint32_t now_ms) const;
  uint16_t mm() const { return mm_; }  // capped at config::kDistanceMaxMm

 private:
  uint16_t mm_ = 0;
  uint32_t last_ok_ms_ = 0;
  bool ever_ok_ = false;
};

}  // namespace sensors
}  // namespace hexapod
