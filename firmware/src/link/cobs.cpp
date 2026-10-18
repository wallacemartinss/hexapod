#include "link/cobs.h"

namespace hexapod {
namespace link {

size_t CobsEncode(const uint8_t* in, size_t len, uint8_t* out, size_t out_cap) {
  if (out_cap < CobsMaxEncodedSize(len)) return 0;
  size_t code_pos = 0;  // where the current block's code byte goes
  size_t out_pos = 1;
  uint8_t code = 1;
  for (size_t i = 0; i < len; ++i) {
    if (in[i] == 0) {
      out[code_pos] = code;
      code_pos = out_pos++;
      code = 1;
      continue;
    }
    out[out_pos++] = in[i];
    if (++code == 0xFF) {  // block full: 254 data bytes
      out[code_pos] = code;
      code_pos = out_pos++;
      code = 1;
    }
  }
  out[code_pos] = code;
  return out_pos;
}

bool CobsDecode(const uint8_t* in, size_t len, uint8_t* out, size_t out_cap,
                size_t* out_len) {
  size_t in_pos = 0;
  size_t out_pos = 0;
  while (in_pos < len) {
    const uint8_t code = in[in_pos++];
    if (code == 0) return false;
    const size_t block = code - 1;
    if (in_pos + block > len || out_pos + block > out_cap) return false;
    for (size_t i = 0; i < block; ++i) {
      if (in[in_pos] == 0) return false;
      out[out_pos++] = in[in_pos++];
    }
    // A short block implies a zero, except at the very end.
    if (code != 0xFF && in_pos < len) {
      if (out_pos >= out_cap) return false;
      out[out_pos++] = 0;
    }
  }
  *out_len = out_pos;
  return true;
}

}  // namespace link
}  // namespace hexapod
