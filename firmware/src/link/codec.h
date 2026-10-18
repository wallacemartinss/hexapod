// Envelope <-> wire frame, on top of nanopb and frame.h.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "hexapod/v1/envelope.pb.h"

namespace hexapod {
namespace link {

// Encodes `envelope` as one complete wire frame. Returns the frame size, or 0
// on failure.
size_t EncodeEnvelopeFrame(const hexapod_v1_Envelope& envelope, uint8_t* out,
                           size_t out_cap);

// All-zero envelope. nanopb's *_init_zero macros only work as initializers, so
// assign from this constant to reset an existing envelope.
extern const hexapod_v1_Envelope kEmptyEnvelope;

// Decodes a frame payload (from FrameDecoder) into `envelope`.
bool DecodeEnvelope(const uint8_t* payload, size_t len,
                    hexapod_v1_Envelope* envelope);

}  // namespace link
}  // namespace hexapod
