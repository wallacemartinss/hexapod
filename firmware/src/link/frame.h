// Serial framing: COBS(payload || CRC16-LE) || 0x00. See proto/README.md.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "hexapod/v1/envelope.pb.h"
#include "link/cobs.h"

namespace hexapod {
namespace link {

constexpr size_t kMaxPayload = hexapod_v1_Envelope_size;     // bytes
constexpr size_t kMaxRaw = kMaxPayload + 2;                  // + CRC16
constexpr size_t kMaxEncoded = CobsMaxEncodedSize(kMaxRaw);  // after COBS
constexpr size_t kMaxFrame = kMaxEncoded + 1;                // + delimiter
static_assert(kMaxRaw <= 254, "frame must fit a single COBS block");

// Builds one wire frame. Returns its size, or 0 if the payload is too large or
// `out_cap` is too small.
size_t EncodeFrame(const uint8_t* payload, size_t len, uint8_t* out,
                   size_t out_cap);

// Byte-at-a-time frame parser with static buffers (no allocation).
// Invalid frames are dropped and counted; parsing resumes at the next 0x00.
class FrameDecoder {
 public:
  enum class Result { kPending, kFrame, kDropped };

  struct Stats {
    uint32_t frames = 0;
    uint32_t cobs_errors = 0;
    uint32_t crc_errors = 0;
    uint32_t overflows = 0;
  };

  // Feeds one byte. On kFrame, payload()/payload_size() hold the frame until
  // the next Push.
  Result Push(uint8_t byte);

  const uint8_t* payload() const { return payload_; }
  size_t payload_size() const { return payload_size_; }
  const Stats& stats() const { return stats_; }

 private:
  Result Finish();

  uint8_t encoded_[kMaxEncoded];
  size_t encoded_size_ = 0;
  bool overflow_ = false;
  uint8_t payload_[kMaxRaw];
  size_t payload_size_ = 0;
  Stats stats_;
};

}  // namespace link
}  // namespace hexapod
