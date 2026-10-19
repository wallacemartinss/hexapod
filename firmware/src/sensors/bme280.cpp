#include "sensors/bme280.h"

namespace hexapod {
namespace sensors {
namespace {

uint16_t U16(const uint8_t* b) { return b[0] | (b[1] << 8); }  // little-endian
int16_t S16(const uint8_t* b) { return static_cast<int16_t>(U16(b)); }

}  // namespace

Bme280Calib ParseBme280Calib(const uint8_t (&tp)[26], const uint8_t (&h)[7]) {
  Bme280Calib c;
  c.t1 = U16(&tp[0]);
  c.t2 = S16(&tp[2]);
  c.t3 = S16(&tp[4]);
  c.p1 = U16(&tp[6]);
  c.p2 = S16(&tp[8]);
  c.p3 = S16(&tp[10]);
  c.p4 = S16(&tp[12]);
  c.p5 = S16(&tp[14]);
  c.p6 = S16(&tp[16]);
  c.p7 = S16(&tp[18]);
  c.p8 = S16(&tp[20]);
  c.p9 = S16(&tp[22]);
  c.h1 = tp[25];  // 0xA1 (0xA0 is unused)
  c.h2 = S16(&h[0]);
  c.h3 = h[2];
  // h4 and h5 are 12-bit, sharing the nibbles of 0xE5.
  c.h4 = static_cast<int16_t>((static_cast<int8_t>(h[3]) * 16) | (h[4] & 0x0F));
  c.h5 = static_cast<int16_t>((static_cast<int8_t>(h[5]) * 16) | (h[4] >> 4));
  c.h6 = static_cast<int8_t>(h[6]);
  return c;
}

EnvReading CompensateBme280(const Bme280Calib& c, int32_t adc_t, int32_t adc_p,
                            int32_t adc_h) {
  EnvReading r;

  // Temperature, 0.01 degC; t_fine feeds the other two.
  int32_t v1 =
      ((((adc_t >> 3) - (static_cast<int32_t>(c.t1) << 1))) * c.t2) >> 11;
  int32_t v2 =
      (((((adc_t >> 4) - c.t1) * ((adc_t >> 4) - c.t1)) >> 12) * c.t3) >> 14;
  const int32_t t_fine = v1 + v2;
  r.temperature_c = ((t_fine * 5 + 128) >> 8) / 100.0f;

  // Pressure, Q24.8 Pa.
  int64_t p1 = static_cast<int64_t>(t_fine) - 128000;
  int64_t p2 = p1 * p1 * c.p6;
  p2 += (p1 * c.p5) << 17;
  p2 += static_cast<int64_t>(c.p4) << 35;
  p1 = ((p1 * p1 * c.p3) >> 8) + ((p1 * c.p2) << 12);
  p1 = (((static_cast<int64_t>(1) << 47) + p1) * c.p1) >> 33;
  if (p1 != 0) {  // 0 would divide by zero (uncalibrated chip)
    int64_t p = 1048576 - adc_p;
    p = (((p << 31) - p2) * 3125) / p1;
    const int64_t q1 =
        (static_cast<int64_t>(c.p9) * (p >> 13) * (p >> 13)) >> 25;
    const int64_t q2 = (static_cast<int64_t>(c.p8) * p) >> 19;
    p = ((p + q1 + q2) >> 8) + (static_cast<int64_t>(c.p7) << 4);
    r.pressure_hpa = static_cast<float>(p) / 256.0f / 100.0f;
  }

  // Humidity, Q22.10 %RH.
  int32_t h = t_fine - 76800;
  h = (((((adc_h << 14) - (static_cast<int32_t>(c.h4) << 20) - (c.h5 * h)) +
         16384) >>
        15) *
       (((((((h * c.h6) >> 10) * (((h * c.h3) >> 11) + 32768)) >> 10) +
          2097152) *
             c.h2 +
         8192) >>
        14));
  h -= (((((h >> 15) * (h >> 15)) >> 7) * c.h1) >> 4);
  if (h < 0) h = 0;
  if (h > 419430400) h = 419430400;
  r.humidity_pct = (h >> 12) / 1024.0f;
  return r;
}

}  // namespace sensors
}  // namespace hexapod
