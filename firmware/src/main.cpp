// Hexapod firmware, milestone 3.1: link only, servos always off.
//
// - PCA9685 OE is driven HIGH before anything else and never released here.
// - The link task answers Hello and sends Telemetry at 10 Hz.
// - Commands are tracked (last_command_seq) but cause no motion; estop latches
//   STATE_ESTOP until reboot. The full failsafe arrives in milestone 3.2.
#include <Arduino.h>
#include <driver/gpio.h>

#include "config.h"
#include "hexapod/v1/envelope.pb.h"
#include "link/codec.h"
#include "link/frame.h"
#include "pins.h"

#ifndef HEXAPOD_FW_VERSION
#define HEXAPOD_FW_VERSION "unknown"
#endif
#ifndef HEXAPOD_FW_GIT_HASH
#define HEXAPOD_FW_GIT_HASH ""
#endif

namespace hexapod {
namespace {

// Set the level before the direction: switching to output first would drive
// the pin LOW for an instant and enable the servos.
void DisableServoOutputs() {
  const auto pin = static_cast<gpio_num_t>(pins::kPcaOe);
  gpio_set_level(pin, 1);
  gpio_set_direction(pin, GPIO_MODE_OUTPUT);
  gpio_set_level(pin, 1);
}

struct LinkState {
  hexapod_v1_State state = hexapod_v1_State_STATE_RELAXED;
  uint32_t telemetry_seq = 0;
  uint32_t last_command_seq = 0;
};

// Static buffers: the link task never allocates.
link::FrameDecoder g_decoder;
uint8_t g_tx_frame[link::kMaxFrame];
hexapod_v1_Envelope g_rx;
hexapod_v1_Envelope g_tx;
LinkState g_link;

void Send(const hexapod_v1_Envelope& envelope) {
  const size_t size =
      link::EncodeEnvelopeFrame(envelope, g_tx_frame, sizeof(g_tx_frame));
  if (size > 0) Serial.write(g_tx_frame, size);
}

void CopyString(char* dst, size_t cap, const char* src) {
  snprintf(dst, cap, "%s", src);
}

void SendHello() {
  g_tx = link::kEmptyEnvelope;
  g_tx.which_payload = hexapod_v1_Envelope_hello_tag;
  hexapod_v1_Hello& hello = g_tx.payload.hello;
  hello.protocol_version = config::kProtocolVersion;
  CopyString(hello.firmware_version, sizeof(hello.firmware_version),
             HEXAPOD_FW_VERSION);
  CopyString(hello.git_hash, sizeof(hello.git_hash), HEXAPOD_FW_GIT_HASH);
  hello.uptime_ms = millis();
  Send(g_tx);
}

void SendTelemetry() {
  g_tx = link::kEmptyEnvelope;
  g_tx.which_payload = hexapod_v1_Envelope_telemetry_tag;
  hexapod_v1_Telemetry& t = g_tx.payload.telemetry;
  t.seq = ++g_link.telemetry_seq;
  t.uptime_ms = millis();
  t.state = g_link.state;
  t.last_command_seq = g_link.last_command_seq;
  t.esp32_temperature_c = temperatureRead();
  // Sensors, gait and joint angles are filled in later milestones (zeros).
  Send(g_tx);
}

void HandleCommand(const hexapod_v1_Command& command) {
  if (command.estop) {
    DisableServoOutputs();
    g_link.state = hexapod_v1_State_STATE_ESTOP;
  }
  if (command.seq > g_link.last_command_seq) {
    g_link.last_command_seq = command.seq;
  }
}

void HandleFrame(const uint8_t* payload, size_t len) {
  if (!link::DecodeEnvelope(payload, len, &g_rx)) return;
  switch (g_rx.which_payload) {
    case hexapod_v1_Envelope_hello_tag:
      SendHello();
      break;
    case hexapod_v1_Envelope_command_tag:
      HandleCommand(g_rx.payload.command);
      break;
    default:
      break;  // not handled yet
  }
}

void LinkTask(void*) {
  SendHello();
  uint32_t next_telemetry = millis();
  for (;;) {
    while (Serial.available() > 0) {
      const int byte = Serial.read();
      if (byte < 0) break;
      if (g_decoder.Push(static_cast<uint8_t>(byte)) ==
          link::FrameDecoder::Result::kFrame) {
        HandleFrame(g_decoder.payload(), g_decoder.payload_size());
      }
    }
    if (static_cast<int32_t>(millis() - next_telemetry) >= 0) {
      next_telemetry += config::kTelemetryPeriodMs;
      SendTelemetry();
    }
    vTaskDelay(pdMS_TO_TICKS(config::kLinkPollPeriodMs));
  }
}

}  // namespace
}  // namespace hexapod

void setup() {
  hexapod::DisableServoOutputs();  // must stay the first statement

  Serial.setRxBufferSize(hexapod::config::kLinkRxBufferSize);
  Serial.begin(hexapod::config::kLinkBaud);

  xTaskCreatePinnedToCore(hexapod::LinkTask, "link",
                          hexapod::config::kLinkTaskStack, nullptr,
                          hexapod::config::kLinkTaskPriority, nullptr,
                          hexapod::config::kLinkTaskCore);
}

void loop() { vTaskDelay(portMAX_DELAY); }
