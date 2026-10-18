#pragma once

#include <stddef.h>
#include <stdint.h>

namespace hexapod {
namespace link {

// CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, xorout 0.
// Check value: "123456789" -> 0x29B1. See proto/README.md.
uint16_t Crc16(const uint8_t* data, size_t len);

}  // namespace link
}  // namespace hexapod
