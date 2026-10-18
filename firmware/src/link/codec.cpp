#include "link/codec.h"

#include <pb_decode.h>
#include <pb_encode.h>

#include "link/frame.h"

namespace hexapod {
namespace link {

const hexapod_v1_Envelope kEmptyEnvelope = hexapod_v1_Envelope_init_zero;

size_t EncodeEnvelopeFrame(const hexapod_v1_Envelope& envelope, uint8_t* out,
                           size_t out_cap) {
  uint8_t payload[kMaxPayload];
  pb_ostream_t stream = pb_ostream_from_buffer(payload, sizeof(payload));
  if (!pb_encode(&stream, hexapod_v1_Envelope_fields, &envelope)) return 0;
  return EncodeFrame(payload, stream.bytes_written, out, out_cap);
}

bool DecodeEnvelope(const uint8_t* payload, size_t len,
                    hexapod_v1_Envelope* envelope) {
  *envelope = kEmptyEnvelope;
  pb_istream_t stream = pb_istream_from_buffer(payload, len);
  return pb_decode(&stream, hexapod_v1_Envelope_fields, envelope);
}

}  // namespace link
}  // namespace hexapod
