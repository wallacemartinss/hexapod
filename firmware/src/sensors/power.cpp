#include "sensors/power.h"

namespace hexapod {
namespace sensors {

PowerReading ConvertIna226(int16_t shunt_raw, uint16_t bus_raw,
                           float shunt_ohm) {
  PowerReading r;
  r.voltage_v = bus_raw * 1.25e-3f;
  r.current_a = shunt_ohm > 0 ? shunt_raw * 2.5e-6f / shunt_ohm : 0;
  // Full scale is +-81.92 mV (+-32767): beyond it the chip clips.
  r.current_saturated = shunt_raw >= 32760 || shunt_raw <= -32760;
  return r;
}

}  // namespace sensors
}  // namespace hexapod
