// Native tests for the MQ-2 alarm: warm-up, baseline, alarm and hysteresis.
#include <unity.h>

#include "config.h"
#include "sensors/gas.h"

using hexapod::sensors::GasMonitor;
using hexapod::sensors::GasReading;
namespace config = hexapod::config;

void setUp() {}
void tearDown() {}

namespace {

// ADC counts for a level in percent.
uint16_t Counts(float pct) {
  return static_cast<uint16_t>(pct / 100.0f * config::kGasAdcFullScale);
}

// Feeds pct for seconds at 10 Hz from t_ms; returns the last reading.
GasReading Feed(GasMonitor& m, float pct, uint32_t& t_ms, int seconds) {
  GasReading r;
  for (int i = 0; i < seconds * 10; ++i, t_ms += 100)
    r = m.Update(Counts(pct), t_ms);
  return r;
}

void test_no_alarm_while_warming_up() {
  GasMonitor m;
  uint32_t t = 0;
  const GasReading r = Feed(m, 90, t, 10);  // smoke-like level, heater cold
  TEST_ASSERT_TRUE(r.warming);
  TEST_ASSERT_FALSE(r.alarm);
  TEST_ASSERT_FLOAT_WITHIN(0.1f, 90, r.level_pct);
}

void test_clean_air_stays_quiet() {
  GasMonitor m;
  uint32_t t = config::kGasWarmupMs;
  const GasReading r = Feed(m, 20, t, 60);
  TEST_ASSERT_FALSE(r.warming);
  TEST_ASSERT_FALSE(r.alarm);
}

void test_smoke_raises_the_alarm_and_clean_air_clears_it() {
  GasMonitor m;
  uint32_t t = config::kGasWarmupMs;
  Feed(m, 20, t, 30);  // baseline ~20 %
  TEST_ASSERT_TRUE(
      Feed(m, 20 + config::kGasAlarmRisePct + 5, t, 2).alarm);  // smoke
  // Still smoky but a bit less: hysteresis keeps the alarm on.
  TEST_ASSERT_TRUE(Feed(m, 20 + config::kGasAlarmRisePct - 2, t, 2).alarm);
  TEST_ASSERT_FALSE(Feed(m, 20, t, 2).alarm);  // clean again
}

void test_baseline_does_not_learn_the_smoke() {
  GasMonitor m;
  uint32_t t = config::kGasWarmupMs;
  Feed(m, 20, t, 30);
  // Smoke for a long time: the baseline must not drift up and silence it.
  TEST_ASSERT_TRUE(Feed(m, 60, t, 600).alarm);
}

void test_slow_drift_is_followed() {
  GasMonitor m;
  uint32_t t = config::kGasWarmupMs;
  float pct = 20;
  GasReading r;
  // +20 points over 20 minutes (temperature/humidity drift): no alarm.
  for (int i = 0; i < 1200 * 10; ++i, t += 100) {
    pct += 20.0f / (1200 * 10);
    r = m.Update(Counts(pct), t);
    TEST_ASSERT_FALSE(r.alarm);
  }
}

}  // namespace

int main() {
  UNITY_BEGIN();
  RUN_TEST(test_no_alarm_while_warming_up);
  RUN_TEST(test_clean_air_stays_quiet);
  RUN_TEST(test_smoke_raises_the_alarm_and_clean_air_clears_it);
  RUN_TEST(test_baseline_does_not_learn_the_smoke);
  RUN_TEST(test_slow_drift_is_followed);
  return UNITY_END();
}
