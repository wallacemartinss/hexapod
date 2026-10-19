// INA226 battery monitor readings. Pure logic: no Arduino.
//
// The current comes from the shunt voltage and the shunt resistance in
// config.h, so it is only right with the shunt actually fitted (CLAUDE.md
// section 9): most modules ship with 0.1 ohm, which saturates at ~0.8 A.
#pragma once

#include <stdint.h>

namespace hexapod {
namespace sensors {

struct PowerReading {
  float voltage_v = 0;             // battery pack (bus voltage)
  float current_a = 0;             // + = drawn from the battery
  bool current_saturated = false;  // shunt voltage at the end of its range
};

// Raw registers: shunt voltage (0x01, signed, 2.5 uV/bit) and bus voltage
// (0x02, 1.25 mV/bit).
PowerReading ConvertIna226(int16_t shunt_raw, uint16_t bus_raw,
                           float shunt_ohm);

// Configuration register (0x00): averaging 16, 1.1 ms conversions, shunt
// and bus continuous (one fresh value every ~35 ms).
constexpr uint16_t kIna226Config = 0x4527;
constexpr uint16_t kIna226ManufacturerId = 0x5449;  // register 0xFE, "TI"

}  // namespace sensors
}  // namespace hexapod
