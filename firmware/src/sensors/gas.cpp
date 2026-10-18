#include "sensors/gas.h"

#include "config.h"

namespace hexapod {
namespace sensors {

GasReading GasMonitor::Update(uint16_t adc, uint32_t now_ms) {
  GasReading r;
  r.level_pct = 100.0f * adc / config::kGasAdcFullScale;
  r.warming = now_ms < config::kGasWarmupMs;
  if (r.warming) return r;  // no baseline, no alarm while the heater settles

  if (!has_baseline_) {
    baseline_ = r.level_pct;
    has_baseline_ = true;
  }
  const float rise = r.level_pct - baseline_;
  if (!alarm_ && rise > config::kGasAlarmRisePct) alarm_ = true;
  if (alarm_ &&
      rise < config::kGasAlarmRisePct - config::kGasAlarmHysteresisPct)
    alarm_ = false;
  // The baseline follows slow drift (temperature, humidity) but not smoke.
  if (!alarm_)
    baseline_ += config::kGasBaselineAlpha * (r.level_pct - baseline_);
  r.alarm = alarm_;
  return r;
}

}  // namespace sensors
}  // namespace hexapod
