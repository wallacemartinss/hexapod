// Native tests for the I2C sensor logic: BME280 compensation, INA226
// conversion, BNO085 orientation and the VL53L0X distance filter.
#include <math.h>
#include <unity.h>

#include "config.h"
#include "sensors/bme280.h"
#include "sensors/distance.h"
#include "sensors/orientation.h"
#include "sensors/power.h"

using namespace hexapod::sensors;
namespace config = hexapod::config;

void setUp() {}
void tearDown() {}

namespace {

// Calibration of the datasheet's worked example (temperature and pressure)
// and typical humidity values.
Bme280Calib ExampleCalib() {
  Bme280Calib c = {};
  c.t1 = 27504;
  c.t2 = 26435;
  c.t3 = -1000;
  c.p1 = 36477;
  c.p2 = -10685;
  c.p3 = 3024;
  c.p4 = 2855;
  c.p5 = 140;
  c.p6 = -7;
  c.p7 = 15500;
  c.p8 = -14600;
  c.p9 = 6000;
  c.h1 = 75;
  c.h2 = 362;
  c.h3 = 0;
  c.h4 = 313;
  c.h5 = 50;
  c.h6 = 30;
  return c;
}

void PutU16(uint8_t* b, uint16_t v) {
  b[0] = v & 0xFF;
  b[1] = v >> 8;
}

Quat AxisAngle(float x, float y, float z, float deg) {
  const float h = deg * 3.14159265f / 360.0f;
  return {cosf(h), x * sinf(h), y * sinf(h), z * sinf(h)};
}

void test_bme280_datasheet_example() {
  const EnvReading r = CompensateBme280(ExampleCalib(), 519888, 415148, 0);
  TEST_ASSERT_FLOAT_WITHIN(0.01f, 25.08f, r.temperature_c);
  TEST_ASSERT_FLOAT_WITHIN(0.05f, 1006.53f, r.pressure_hpa);
}

void test_bme280_humidity_is_bounded_and_rises_with_the_reading() {
  const Bme280Calib c = ExampleCalib();
  float last = -1;
  for (int32_t adc_h = 0; adc_h <= 65535; adc_h += 4096) {
    const float h = CompensateBme280(c, 519888, 415148, adc_h).humidity_pct;
    TEST_ASSERT_TRUE(h >= 0 && h <= 100);
    TEST_ASSERT_TRUE(h >= last);
    last = h;
  }
  TEST_ASSERT_EQUAL_FLOAT(100, last);  // clamped at the top
}

void test_bme280_uncalibrated_chip_gives_no_pressure() {
  Bme280Calib c = ExampleCalib();
  c.p1 = 0;  // would divide by zero
  TEST_ASSERT_EQUAL_FLOAT(0,
                          CompensateBme280(c, 519888, 415148, 0).pressure_hpa);
}

void test_bme280_calibration_registers_parse() {
  const Bme280Calib want = ExampleCalib();
  uint8_t tp[26] = {};
  const uint16_t words[12] = {want.t1,
                              static_cast<uint16_t>(want.t2),
                              static_cast<uint16_t>(want.t3),
                              want.p1,
                              static_cast<uint16_t>(want.p2),
                              static_cast<uint16_t>(want.p3),
                              static_cast<uint16_t>(want.p4),
                              static_cast<uint16_t>(want.p5),
                              static_cast<uint16_t>(want.p6),
                              static_cast<uint16_t>(want.p7),
                              static_cast<uint16_t>(want.p8),
                              static_cast<uint16_t>(want.p9)};
  for (int i = 0; i < 12; ++i) PutU16(&tp[i * 2], words[i]);
  tp[25] = want.h1;
  // h4 = 0xE4:0xE5[3:0], h5 = 0xE6:0xE5[7:4].
  const uint8_t h[7] = {
      static_cast<uint8_t>(want.h2 & 0xFF),
      static_cast<uint8_t>(want.h2 >> 8),
      want.h3,
      static_cast<uint8_t>(want.h4 >> 4),
      static_cast<uint8_t>((want.h4 & 0x0F) | ((want.h5 & 0x0F) << 4)),
      static_cast<uint8_t>(want.h5 >> 4),
      static_cast<uint8_t>(want.h6)};
  const Bme280Calib c = ParseBme280Calib(tp, h);
  TEST_ASSERT_EQUAL(want.t1, c.t1);
  TEST_ASSERT_EQUAL(want.t3, c.t3);
  TEST_ASSERT_EQUAL(want.p2, c.p2);
  TEST_ASSERT_EQUAL(want.p9, c.p9);
  TEST_ASSERT_EQUAL(want.h1, c.h1);
  TEST_ASSERT_EQUAL(want.h2, c.h2);
  TEST_ASSERT_EQUAL(want.h4, c.h4);
  TEST_ASSERT_EQUAL(want.h5, c.h5);
  TEST_ASSERT_EQUAL(want.h6, c.h6);
}

void test_ina226_voltage_and_current() {
  // 12.0 V; 10 mV across 2 mohm = 5 A.
  const PowerReading r = ConvertIna226(4000, 9600, 0.002f);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 12.0f, r.voltage_v);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 5.0f, r.current_a);
  TEST_ASSERT_FALSE(r.current_saturated);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, -5.0f,
                           ConvertIna226(-4000, 9600, 0.002f).current_a);
}

void test_ina226_stock_shunt_saturates() {
  // 0.1 ohm (the stock R100) at 2 A would be 200 mV: the chip clips at 81.92.
  const PowerReading r = ConvertIna226(32767, 9600, 0.1f);
  TEST_ASSERT_TRUE(r.current_saturated);
  TEST_ASSERT_TRUE(r.current_a < 0.82f);
}

void test_orientation_level_and_axes() {
  Orientation o = ToOrientation(Quat{});
  TEST_ASSERT_FLOAT_WITHIN(0.01f, 0, o.roll_deg);
  TEST_ASSERT_FLOAT_WITHIN(0.01f, 0, o.pitch_deg);
  TEST_ASSERT_FLOAT_WITHIN(0.01f, 0, o.yaw_deg);

  // About +x (forward): the left side rises, the right goes down.
  o = ToOrientation(AxisAngle(1, 0, 0, 30));
  TEST_ASSERT_FLOAT_WITHIN(0.05f, 30, o.roll_deg);
  TEST_ASSERT_FLOAT_WITHIN(0.05f, 0, o.pitch_deg);
  // About +y (left): the nose goes down.
  o = ToOrientation(AxisAngle(0, 1, 0, 20));
  TEST_ASSERT_FLOAT_WITHIN(0.05f, 20, o.pitch_deg);
  // About +z (up): turned left.
  o = ToOrientation(AxisAngle(0, 0, 1, 90));
  TEST_ASSERT_FLOAT_WITHIN(0.05f, 90, o.yaw_deg);
  TEST_ASSERT_FLOAT_WITHIN(0.05f, 0, o.roll_deg);
}

void test_orientation_normalizes_and_survives_zero() {
  Quat q = AxisAngle(1, 0, 0, 40);
  q.w *= 3;
  q.x *= 3;
  const Orientation o = ToOrientation(q);
  TEST_ASSERT_FLOAT_WITHIN(0.05f, 40, o.roll_deg);
  TEST_ASSERT_TRUE(o.roll_deg > config::kTippedDeg);
  TEST_ASSERT_FLOAT_WITHIN(1e-4f, 1, o.q.w * o.q.w + o.q.x * o.q.x);

  const Orientation z = ToOrientation(Quat{0, 0, 0, 0});
  TEST_ASSERT_FLOAT_WITHIN(0.01f, 0, z.roll_deg);
  TEST_ASSERT_FALSE(isnan(z.pitch_deg));
}

void test_distance_never_valid_before_a_reading() {
  DistanceFilter d;
  TEST_ASSERT_FALSE(d.valid(0));
  d.Update(0, true, 100);  // timeout
  TEST_ASSERT_FALSE(d.valid(100));
}

void test_distance_out_of_range_is_far_not_a_fault() {
  DistanceFilter d;
  d.Update(8190, false, 100);
  TEST_ASSERT_TRUE(d.valid(100));
  TEST_ASSERT_EQUAL(config::kDistanceMaxMm, d.mm());
  d.Update(120, false, 150);
  TEST_ASSERT_EQUAL(120, d.mm());
}

void test_distance_goes_stale_without_answers() {
  DistanceFilter d;
  d.Update(300, false, 1000);
  d.Update(0, true, 1100);  // a missed reading keeps the last one
  TEST_ASSERT_TRUE(d.valid(1100));
  TEST_ASSERT_EQUAL(300, d.mm());
  TEST_ASSERT_TRUE(d.valid(1000 + config::kSensorStaleMs));
  TEST_ASSERT_FALSE(d.valid(1001 + config::kSensorStaleMs));
}

}  // namespace

int main() {
  UNITY_BEGIN();
  RUN_TEST(test_bme280_datasheet_example);
  RUN_TEST(test_bme280_humidity_is_bounded_and_rises_with_the_reading);
  RUN_TEST(test_bme280_uncalibrated_chip_gives_no_pressure);
  RUN_TEST(test_bme280_calibration_registers_parse);
  RUN_TEST(test_ina226_voltage_and_current);
  RUN_TEST(test_ina226_stock_shunt_saturates);
  RUN_TEST(test_orientation_level_and_axes);
  RUN_TEST(test_orientation_normalizes_and_survives_zero);
  RUN_TEST(test_distance_never_valid_before_a_reading);
  RUN_TEST(test_distance_out_of_range_is_far_not_a_fault);
  RUN_TEST(test_distance_goes_stale_without_answers);
  return UNITY_END();
}
