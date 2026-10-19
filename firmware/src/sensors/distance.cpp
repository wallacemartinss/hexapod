#include "sensors/distance.h"

#include "config.h"

namespace hexapod {
namespace sensors {

void DistanceFilter::Update(uint16_t raw_mm, bool timeout, uint32_t now_ms) {
  if (timeout) return;  // keeps the last value until it goes stale
  mm_ = raw_mm > config::kDistanceMaxMm ? config::kDistanceMaxMm : raw_mm;
  last_ok_ms_ = now_ms;
  ever_ok_ = true;
}

bool DistanceFilter::valid(uint32_t now_ms) const {
  return ever_ok_ && now_ms - last_ok_ms_ <= config::kSensorStaleMs;
}

}  // namespace sensors
}  // namespace hexapod
