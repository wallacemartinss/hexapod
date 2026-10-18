// Native tests for the serial link: CRC16, COBS, framing and nanopb codec.
#include <string.h>
#include <unity.h>

#include "link/cobs.h"
#include "link/codec.h"
#include "link/crc16.h"
#include "link/frame.h"

using hexapod::link::CobsDecode;
using hexapod::link::CobsEncode;
using hexapod::link::CobsMaxEncodedSize;
using hexapod::link::Crc16;
using hexapod::link::DecodeEnvelope;
using hexapod::link::EncodeEnvelopeFrame;
using hexapod::link::EncodeFrame;
using hexapod::link::FrameDecoder;
using hexapod::link::kMaxFrame;
using hexapod::link::kMaxPayload;

void setUp() {}
void tearDown() {}

namespace {

// Feeds bytes; returns how many complete frames were accepted.
int FeedAll(FrameDecoder& decoder, const uint8_t* data, size_t len) {
  int frames = 0;
  for (size_t i = 0; i < len; ++i) {
    if (decoder.Push(data[i]) == FrameDecoder::Result::kFrame) ++frames;
  }
  return frames;
}

hexapod_v1_Envelope SampleTelemetry() {
  hexapod_v1_Envelope e = hexapod_v1_Envelope_init_zero;
  e.which_payload = hexapod_v1_Envelope_telemetry_tag;
  hexapod_v1_Telemetry& t = e.payload.telemetry;
  t.seq = 42;
  t.state = hexapod_v1_State_STATE_SAFE_SIT;
  t.fault_flags = hexapod_v1_Fault_FAULT_IMU;
  t.battery_voltage_v = 11.1f;
  t.distances_mm[3] = 8190;
  for (int i = 0; i < 18; ++i) t.joint_angles_deg[i] = i * 1.5f;
  return e;
}

void CobsRoundTrip(const uint8_t* in, size_t len) {
  uint8_t encoded[CobsMaxEncodedSize(600)];
  uint8_t decoded[600];
  const size_t enc = CobsEncode(in, len, encoded, sizeof(encoded));
  TEST_ASSERT_TRUE(enc > 0);
  TEST_ASSERT_TRUE(enc <= CobsMaxEncodedSize(len));
  for (size_t i = 0; i < enc; ++i) TEST_ASSERT_NOT_EQUAL(0, encoded[i]);
  size_t dec_len = 0;
  TEST_ASSERT_TRUE(
      CobsDecode(encoded, enc, decoded, sizeof(decoded), &dec_len));
  TEST_ASSERT_EQUAL(len, dec_len);
  if (len > 0) TEST_ASSERT_EQUAL_MEMORY(in, decoded, len);
}

}  // namespace

void test_crc16_check_value() {
  const char* check = "123456789";
  TEST_ASSERT_EQUAL_HEX16(0x29B1,
                          Crc16(reinterpret_cast<const uint8_t*>(check), 9));
}

void test_cobs_round_trip_edge_cases() {
  uint8_t buf[600] = {};
  CobsRoundTrip(buf, 0);

  const uint8_t zeros[] = {0, 0, 0};
  CobsRoundTrip(zeros, sizeof(zeros));

  const uint8_t mixed[] = {0x11, 0x00, 0x22, 0x33, 0x00};
  CobsRoundTrip(mixed, sizeof(mixed));

  // Block boundaries: 253, 254 and 255 non-zero bytes, then 600.
  for (size_t i = 0; i < sizeof(buf); ++i)
    buf[i] = static_cast<uint8_t>(i % 255 + 1);
  CobsRoundTrip(buf, 253);
  CobsRoundTrip(buf, 254);
  CobsRoundTrip(buf, 255);
  CobsRoundTrip(buf, 600);
}

void test_cobs_known_vector() {
  const uint8_t in[] = {0x11, 0x22, 0x00, 0x33};
  const uint8_t expected[] = {0x03, 0x11, 0x22, 0x02, 0x33};
  uint8_t out[8];
  TEST_ASSERT_EQUAL(sizeof(expected),
                    CobsEncode(in, sizeof(in), out, sizeof(out)));
  TEST_ASSERT_EQUAL_MEMORY(expected, out, sizeof(expected));
}

void test_cobs_rejects_malformed() {
  uint8_t out[16];
  size_t len = 0;
  const uint8_t embedded_zero[] = {0x03, 0x11, 0x00};
  TEST_ASSERT_FALSE(
      CobsDecode(embedded_zero, sizeof(embedded_zero), out, sizeof(out), &len));
  const uint8_t past_end[] = {0x05, 0x11, 0x22};
  TEST_ASSERT_FALSE(
      CobsDecode(past_end, sizeof(past_end), out, sizeof(out), &len));
}

void test_envelope_frame_round_trip() {
  const hexapod_v1_Envelope sent = SampleTelemetry();
  uint8_t frame[kMaxFrame];
  const size_t size = EncodeEnvelopeFrame(sent, frame, sizeof(frame));
  TEST_ASSERT_TRUE(size > 0);
  TEST_ASSERT_EQUAL_HEX8(0x00, frame[size - 1]);

  FrameDecoder decoder;
  TEST_ASSERT_EQUAL(1, FeedAll(decoder, frame, size));
  hexapod_v1_Envelope got;
  TEST_ASSERT_TRUE(
      DecodeEnvelope(decoder.payload(), decoder.payload_size(), &got));
  TEST_ASSERT_EQUAL(hexapod_v1_Envelope_telemetry_tag, got.which_payload);
  TEST_ASSERT_EQUAL_UINT32(42, got.payload.telemetry.seq);
  TEST_ASSERT_EQUAL(hexapod_v1_State_STATE_SAFE_SIT,
                    got.payload.telemetry.state);
  TEST_ASSERT_EQUAL_UINT32(8190, got.payload.telemetry.distances_mm[3]);
  TEST_ASSERT_EQUAL_FLOAT(25.5f, got.payload.telemetry.joint_angles_deg[17]);
}

void test_corrupted_frame_is_dropped() {
  const hexapod_v1_Envelope sent = SampleTelemetry();
  uint8_t frame[kMaxFrame];
  const size_t size = EncodeEnvelopeFrame(sent, frame, sizeof(frame));

  // Flip every bit of every byte (except the delimiter), one at a time:
  // no corrupted frame may be accepted.
  for (size_t i = 0; i + 1 < size; ++i) {
    for (int bit = 0; bit < 8; ++bit) {
      uint8_t bad[kMaxFrame];
      memcpy(bad, frame, size);
      bad[i] ^= static_cast<uint8_t>(1 << bit);
      FrameDecoder decoder;
      TEST_ASSERT_EQUAL(0, FeedAll(decoder, bad, size));
    }
  }
}

void test_truncated_frame_is_dropped() {
  const hexapod_v1_Envelope sent = SampleTelemetry();
  uint8_t frame[kMaxFrame];
  const size_t size = EncodeEnvelopeFrame(sent, frame, sizeof(frame));
  frame[size / 2] = 0x00;  // early delimiter cuts the frame
  FrameDecoder decoder;
  TEST_ASSERT_EQUAL(0, FeedAll(decoder, frame, size / 2 + 1));
}

void test_resync_after_garbage() {
  // Noise without delimiter (e.g. ROM boot log), then a delimiter, then a
  // frame.
  uint8_t stream[kMaxFrame + 64];
  size_t pos = 0;
  for (int i = 0; i < 40; ++i)
    stream[pos++] = static_cast<uint8_t>(0x41 + i % 26);
  stream[pos++] = 0x00;
  const hexapod_v1_Envelope sent = SampleTelemetry();
  pos += EncodeEnvelopeFrame(sent, stream + pos, sizeof(stream) - pos);

  FrameDecoder decoder;
  TEST_ASSERT_EQUAL(1, FeedAll(decoder, stream, pos));
  TEST_ASSERT_EQUAL_UINT32(1, decoder.stats().frames);
}

void test_oversized_input_is_dropped_then_recovers() {
  FrameDecoder decoder;
  for (size_t i = 0; i < kMaxFrame * 3; ++i) decoder.Push(0x55);
  TEST_ASSERT_EQUAL(FrameDecoder::Result::kDropped, decoder.Push(0x00));
  TEST_ASSERT_EQUAL_UINT32(1, decoder.stats().overflows);

  const hexapod_v1_Envelope sent = SampleTelemetry();
  uint8_t frame[kMaxFrame];
  const size_t size = EncodeEnvelopeFrame(sent, frame, sizeof(frame));
  TEST_ASSERT_EQUAL(1, FeedAll(decoder, frame, size));
}

void test_payload_limit() {
  uint8_t payload[kMaxPayload + 1] = {};
  uint8_t frame[kMaxFrame + 8];
  TEST_ASSERT_TRUE(EncodeFrame(payload, kMaxPayload, frame, sizeof(frame)) <=
                   kMaxFrame);
  TEST_ASSERT_EQUAL(
      0, EncodeFrame(payload, kMaxPayload + 1, frame, sizeof(frame)));
}

int main() {
  UNITY_BEGIN();
  RUN_TEST(test_crc16_check_value);
  RUN_TEST(test_cobs_round_trip_edge_cases);
  RUN_TEST(test_cobs_known_vector);
  RUN_TEST(test_cobs_rejects_malformed);
  RUN_TEST(test_envelope_frame_round_trip);
  RUN_TEST(test_corrupted_frame_is_dropped);
  RUN_TEST(test_truncated_frame_is_dropped);
  RUN_TEST(test_resync_after_garbage);
  RUN_TEST(test_oversized_input_is_dropped_then_recovers);
  RUN_TEST(test_payload_limit);
  return UNITY_END();
}
