#pragma once

#include <stddef.h>
#include <stdint.h>

namespace hexapod {
namespace link {

// Worst-case COBS output size for `len` input bytes (no delimiter).
constexpr size_t CobsMaxEncodedSize(size_t len) { return len + len / 254 + 1; }

// Consistent Overhead Byte Stuffing. The output contains no 0x00 byte; the
// caller appends the 0x00 frame delimiter.
// Returns the encoded size, or 0 if `out_cap` is too small.
size_t CobsEncode(const uint8_t* in, size_t len, uint8_t* out, size_t out_cap);

// Reverses CobsEncode (input without the delimiter).
// Returns false on malformed input (a 0x00 byte, a code past the end) or if
// `out_cap` is too small.
bool CobsDecode(const uint8_t* in, size_t len, uint8_t* out, size_t out_cap,
                size_t* out_len);

}  // namespace link
}  // namespace hexapod
