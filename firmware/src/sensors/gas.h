// MQ-2 smoke/gas alarm. Pure logic: no Arduino. The level is relative (ADC
// percentage of full scale), so the alarm compares it with a clean-air
// baseline learned after warm-up instead of a fixed ppm figure.
#pragma once

#include <stdint.h>

namespace hexapod {
namespace sensors {

struct GasReading {
  float level_pct = 0;   // 0..100 % of the ADC full scale
  bool warming = true;   // heater not settled yet: level not trusted
  bool alarm = false;    // level well above the clean-air baseline
};

class GasMonitor {
 public:
  // One ADC sample (counts) taken at uptime now_ms.
  GasReading Update(uint16_t adc, uint32_t now_ms);

 private:
  float baseline_ = 0;
  bool has_baseline_ = false;
  bool alarm_ = false;
};

}  // namespace sensors
}  // namespace hexapod
