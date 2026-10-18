#include "link/frame.h"

#include <string.h>

#include "link/crc16.h"

namespace hexapod {
namespace link {

size_t EncodeFrame(const uint8_t* payload, size_t len, uint8_t* out,
                   size_t out_cap) {
  if (len > kMaxPayload) return 0;
  uint8_t raw[kMaxRaw];
  memcpy(raw, payload, len);
  const uint16_t crc = Crc16(payload, len);
  raw[len] = static_cast<uint8_t>(crc & 0xFF);
  raw[len + 1] = static_cast<uint8_t>(crc >> 8);
  if (out_cap < 1) return 0;
  const size_t encoded = CobsEncode(raw, len + 2, out, out_cap - 1);
  if (encoded == 0) return 0;
  out[encoded] = 0x00;
  return encoded + 1;
}

FrameDecoder::Result FrameDecoder::Push(uint8_t byte) {
  if (byte == 0x00) return Finish();
  if (encoded_size_ == sizeof(encoded_)) {
    overflow_ = true;  // keep discarding until the delimiter
    return Result::kPending;
  }
  encoded_[encoded_size_++] = byte;
  return Result::kPending;
}

FrameDecoder::Result FrameDecoder::Finish() {
  const size_t size = encoded_size_;
  const bool overflow = overflow_;
  encoded_size_ = 0;
  overflow_ = false;

  if (overflow) {
    ++stats_.overflows;
    return Result::kDropped;
  }
  if (size == 0) return Result::kPending;  // idle delimiters resync the link

  size_t raw_size = 0;
  if (!CobsDecode(encoded_, size, payload_, sizeof(payload_), &raw_size) ||
      raw_size < 2) {
    ++stats_.cobs_errors;
    return Result::kDropped;
  }
  const size_t len = raw_size - 2;
  const uint16_t received =
      static_cast<uint16_t>(payload_[len] | (payload_[len + 1] << 8));
  if (Crc16(payload_, len) != received) {
    ++stats_.crc_errors;
    return Result::kDropped;
  }
  payload_size_ = len;
  ++stats_.frames;
  return Result::kFrame;
}

}  // namespace link
}  // namespace hexapod
