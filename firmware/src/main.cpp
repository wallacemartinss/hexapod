// Hexapod firmware, milestone 3.3: link + failsafe + gait "on paper", servos
// always off.
//
// - PCA9685 OE is driven HIGH before anything else. While
//   config::kServoOutputsAllowed is false it is never released, whatever the
//   failsafe allows.
// - link task (core 0): decodes frames, answers Hello, queues Command and
//   LinkConfig, sends Telemetry at 10 Hz. estop also cuts OE right here.
// - motion task (core 1, 50 Hz): failsafe -> gait -> IK -> joint speed limit.
//   The 18 joint angles go out in Telemetry; no servo is driven yet and
//   sensors are not read yet (reported as faults).
// - Both tasks are under the task watchdog: a hang resets the chip.
#include <Arduino.h>
#include <driver/gpio.h>
#include <esp_task_wdt.h>
#include <freertos/queue.h>

#include "config.h"
#include "hexapod/v1/envelope.pb.h"
#include "link/codec.h"
#include "link/frame.h"
#include "motion/controller.h"
#include "pins.h"
#include "safety/failsafe.h"

#ifndef HEXAPOD_FW_VERSION
#define HEXAPOD_FW_VERSION "unknown"
#endif
#ifndef HEXAPOD_FW_GIT_HASH
#define HEXAPOD_FW_GIT_HASH ""
#endif

static_assert(!hexapod::config::kServoOutputsAllowed,
              "no servo driver yet: OE must stay HIGH");

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

// --- Shared between tasks ---

// link -> motion
struct LinkEvent {
  enum class Kind : uint8_t { kCommand, kLinkConfig };
  Kind kind;
  uint32_t received_ms;
  safety::CommandInput command;
  motion::MotionInput motion;
  hexapod_v1_LinkProfile profile;
};
QueueHandle_t g_events;

// motion -> link (telemetry), guarded by g_status_lock.
struct Status {
  hexapod_v1_State state = hexapod_v1_State_STATE_RELAXED;
  uint32_t fault_flags = 0;
  uint32_t blocked_mask = 0;
  uint32_t last_command_seq = 0;
  uint32_t loop_time_us = 0;
  hexapod_v1_Mode mode = hexapod_v1_Mode_MODE_SIT;
  float joint_angles_deg[motion::kLegCount * 3] = {};
};
Status g_status;
portMUX_TYPE g_status_lock = portMUX_INITIALIZER_UNLOCKED;

// --- motion task ---

safety::Failsafe g_failsafe;
motion::MotionController g_motion;

void MotionTask(void*) {
  esp_task_wdt_add(nullptr);
  const safety::SensorInputs sensors;  // TODO(3.4): real sensor readings
  motion::MotionInput pilot;           // from the last valid Command
  constexpr float kDt = config::kMotionPeriodMs / 1000.0f;
  TickType_t wake = xTaskGetTickCount();
  for (;;) {
    vTaskDelayUntil(&wake, pdMS_TO_TICKS(config::kMotionPeriodMs));
    const uint32_t start_us = micros();

    LinkEvent event;
    while (xQueueReceive(g_events, &event, 0) == pdTRUE) {
      if (event.kind == LinkEvent::Kind::kCommand) {
        if (g_failsafe.OnCommand(event.command, event.received_ms)) {
          pilot = event.motion;
        }
      } else {
        g_failsafe.SetProfile(event.profile);
      }
    }

    const safety::Output& out = g_failsafe.Update(sensors, millis());
    g_motion.Update(pilot, out, kDt);
    pilot.mode = hexapod_v1_Mode_MODE_UNSPECIFIED;  // a mode applies once
    DisableServoOutputs();  // kServoOutputsAllowed is false (see top)

    const uint32_t loop_us = micros() - start_us;
    uint32_t faults = out.fault_flags;
    if (loop_us > config::kMotionPeriodMs * 1000) {
      faults |= hexapod_v1_Fault_FAULT_LOOP_OVERRUN;
    }
    portENTER_CRITICAL(&g_status_lock);
    g_status.state = out.state;
    g_status.fault_flags = faults;
    g_status.blocked_mask = out.blocked_mask;
    g_status.last_command_seq = g_failsafe.last_command_seq();
    g_status.loop_time_us = loop_us;
    g_status.mode = g_motion.mode();
    for (int leg = 0; leg < motion::kLegCount; ++leg) {
      const motion::JointAngles& j = g_motion.joints(leg);
      g_status.joint_angles_deg[leg * 3 + 0] = j.coxa_deg;
      g_status.joint_angles_deg[leg * 3 + 1] = j.femur_deg;
      g_status.joint_angles_deg[leg * 3 + 2] = j.tibia_deg;
    }
    portEXIT_CRITICAL(&g_status_lock);

    esp_task_wdt_reset();
  }
}

// --- link task (static buffers: never allocates) ---

link::FrameDecoder g_decoder;
uint8_t g_tx_frame[link::kMaxFrame];
hexapod_v1_Envelope g_rx;
hexapod_v1_Envelope g_tx;
uint32_t g_telemetry_seq = 0;

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
  portENTER_CRITICAL(&g_status_lock);
  const Status status = g_status;
  portEXIT_CRITICAL(&g_status_lock);

  g_tx = link::kEmptyEnvelope;
  g_tx.which_payload = hexapod_v1_Envelope_telemetry_tag;
  hexapod_v1_Telemetry& t = g_tx.payload.telemetry;
  t.seq = ++g_telemetry_seq;
  t.uptime_ms = millis();
  t.state = status.state;
  t.fault_flags = status.fault_flags;
  t.blocked_mask = status.blocked_mask;
  t.last_command_seq = status.last_command_seq;
  t.loop_time_us = status.loop_time_us;
  t.mode = status.mode;
  t.gait = hexapod_v1_Gait_GAIT_TRIPOD;  // the only gait so far
  for (int i = 0; i < motion::kLegCount * 3; ++i) {
    t.joint_angles_deg[i] = status.joint_angles_deg[i];
  }
  t.esp32_temperature_c = temperatureRead();
  // Sensor fields are filled in milestone 3.4 (zeros until then).
  Send(g_tx);
}

void QueueEvent(const LinkEvent& event) {
  // A full queue drops the event: to the failsafe that is a lost command.
  xQueueSend(g_events, &event, 0);
}

void HandleFrame(const uint8_t* payload, size_t len) {
  if (!link::DecodeEnvelope(payload, len, &g_rx)) return;
  LinkEvent event = {};
  event.received_ms = millis();
  switch (g_rx.which_payload) {
    case hexapod_v1_Envelope_hello_tag:
      SendHello();
      break;
    case hexapod_v1_Envelope_command_tag: {
      const hexapod_v1_Command& c = g_rx.payload.command;
      if (c.estop) DisableServoOutputs();  // at once, before the queue
      event.kind = LinkEvent::Kind::kCommand;
      event.command.seq = c.seq;
      event.command.mode = c.mode;
      event.command.estop = c.estop;
      event.motion.mode = c.mode;
      event.motion.vx = c.vx;
      event.motion.vy = c.vy;
      event.motion.yaw_rate = c.yaw_rate;
      event.motion.body_height = c.body_height;
      event.motion.body_roll = c.body_roll;
      event.motion.body_pitch = c.body_pitch;
      event.motion.body_yaw = c.body_yaw;
      QueueEvent(event);
      break;
    }
    case hexapod_v1_Envelope_link_config_tag:
      event.kind = LinkEvent::Kind::kLinkConfig;
      event.profile = g_rx.payload.link_config.profile;
      QueueEvent(event);
      break;
    default:
      break;  // calibration and others: later milestones
  }
}

void LinkTask(void*) {
  esp_task_wdt_add(nullptr);
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
    esp_task_wdt_reset();
    vTaskDelay(pdMS_TO_TICKS(config::kLinkPollPeriodMs));
  }
}

}  // namespace
}  // namespace hexapod

void setup() {
  hexapod::DisableServoOutputs();  // must stay the first statement

  // Already running with the Arduino defaults; this shortens the timeout.
  esp_task_wdt_init(hexapod::config::kTaskWatchdogS, true);

  Serial.setRxBufferSize(hexapod::config::kLinkRxBufferSize);
  Serial.begin(hexapod::config::kLinkBaud);

  hexapod::g_events = xQueueCreate(hexapod::config::kLinkQueueLength,
                                   sizeof(hexapod::LinkEvent));

  xTaskCreatePinnedToCore(hexapod::MotionTask, "motion",
                          hexapod::config::kMotionTaskStack, nullptr,
                          hexapod::config::kMotionTaskPriority, nullptr,
                          hexapod::config::kMotionTaskCore);
  xTaskCreatePinnedToCore(hexapod::LinkTask, "link",
                          hexapod::config::kLinkTaskStack, nullptr,
                          hexapod::config::kLinkTaskPriority, nullptr,
                          hexapod::config::kLinkTaskCore);
}

void loop() { vTaskDelay(portMAX_DELAY); }
