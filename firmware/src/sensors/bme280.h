// BME280 compensation (Bosch datasheet BST-BME280-DS002, section 4.2.3).
// Pure logic: no Arduino. The driver reads the calibration block once and
// the raw ADC values each second; this turns them into SI-ish units.
#pragma once

#include <stdint.h>

namespace hexapod {
namespace sensors {

struct Bme280Calib {
  uint16_t t1;
  int16_t t2, t3;
  uint16_t p1;
  int16_t p2, p3, p4, p5, p6, p7, p8, p9;
  uint8_t h1;
  int16_t h2;
  uint8_t h3;
  int16_t h4, h5;
  int8_t h6;
};

struct EnvReading {
  float temperature_c = 0;
  float humidity_pct = 0;  // relative, 0..100
  float pressure_hpa = 0;
};

// Calibration from the two register blocks: 0x88..0xA1 (26 bytes) and
// 0xE1..0xE7 (7 bytes).
Bme280Calib ParseBme280Calib(const uint8_t (&tp)[26], const uint8_t (&h)[7]);

// Raw 20-bit temperature and pressure, 16-bit humidity -> units.
EnvReading CompensateBme280(const Bme280Calib& c, int32_t adc_t, int32_t adc_p,
                            int32_t adc_h);

}  // namespace sensors
}  // namespace hexapod
