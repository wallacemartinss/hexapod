// Physical and timing constants of the hexapod firmware, in one place.
// Every value carries its unit in the comment.
#pragma once

#include <stdint.h>

namespace hexapod {
namespace config {

// --- Link (USB serial to the Pi) ---
// Wire contract version; see proto/README.md. Bump with any incompatible change.
constexpr uint32_t kProtocolVersion = 1;
// bit/s. Used by the CP2102 of the bench board; ignored by the S3 native USB.
constexpr uint32_t kLinkBaud = 115200;
constexpr uint32_t kLinkRxBufferSize = 1024;  // bytes
constexpr uint32_t kTelemetryPeriodMs = 100;  // ms (10 Hz)
constexpr uint32_t kLinkPollPeriodMs = 2;     // ms between serial reads

// --- FreeRTOS tasks ---
constexpr uint32_t kLinkTaskStack = 6144;  // bytes
constexpr uint32_t kLinkTaskPriority = 3;
constexpr int kLinkTaskCore = 0;

}  // namespace config
}  // namespace hexapod
