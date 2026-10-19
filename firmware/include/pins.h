// Pin map and wiring of the hexapod controller.
// Wiring notes and tables: firmware/PINOUT.md and its Portuguese copy
// firmware/PINOUT.pt-BR.md (keep all three in sync).
//
// The board is selected by the target the firmware is built for:
//   esp32s3  -> ESP32-S3 SuperMini (final robot)
//   esp32dev -> ESP32 DevKit 38-pin, ESP-WROOM-32 (bench tests only)
#pragma once

#include <stdint.h>

namespace hexapod {
namespace pins {

#if defined(CONFIG_IDF_TARGET_ESP32S3)

// ESP32-S3 SuperMini. Avoided: GPIO0/3/45/46 (strapping), GPIO19/20 (native
// USB), GPIO26-32 (flash/PSRAM).
// TODO(hardware): confirm the exposed pads on the board received.

// PCA9685 OE of both boards. HIGH = outputs off. Needs an external pull-up.
constexpr uint8_t kPcaOe = 1;
constexpr uint8_t kLedData = 2;  // WS2812 data in
// I2C0, 400 kHz: PCA9685 0x40/0x41.
constexpr uint8_t kServoSda = 4;
constexpr uint8_t kServoScl = 5;
// I2C1: VL53L0X, BNO085, BME280, INA226.
constexpr uint8_t kSensorSda = 6;
constexpr uint8_t kSensorScl = 7;
// VL53L0X XSHUT: front, right, rear, left. (GPIO14 keeps GPIO10, on ADC1,
// free for the MQ-2.)
constexpr uint8_t kXshut[4] = {8, 9, 14, 11};
constexpr uint8_t kImuInt = 12;    // BNO085 INT (active low)
constexpr uint8_t kImuReset = 13;  // BNO085 RST (active low)
constexpr uint8_t kGasAdc = 10;    // MQ-2 AO through a 10k/15k divider (ADC1)
// UART to the eyes ESP32 (future). The ROM boot log also appears on TX.
constexpr uint8_t kEyesTx = 43;
constexpr uint8_t kEyesRx = 44;
constexpr uint8_t kStatusLed = 48;  // on-board RGB LED

#elif defined(CONFIG_IDF_TARGET_ESP32)

// ESP32 DevKit 38-pin (ESP-WROOM-32), bench tests. Avoided: GPIO6-11 (flash),
// GPIO0/2/5/12/15 (strapping), GPIO1/3 (UART0 = USB link via CP2102).

// PCA9685 OE of both boards. HIGH = outputs off. Needs an external pull-up.
constexpr uint8_t kPcaOe = 27;
constexpr uint8_t kLedData = 23;  // WS2812 data in
// I2C0, 400 kHz: PCA9685 0x40/0x41.
constexpr uint8_t kServoSda = 21;
constexpr uint8_t kServoScl = 22;
// I2C1: VL53L0X, BNO085, BME280, INA226.
constexpr uint8_t kSensorSda = 32;
constexpr uint8_t kSensorScl = 33;
// VL53L0X XSHUT: front, right, rear, left.
constexpr uint8_t kXshut[4] = {18, 19, 13, 14};
constexpr uint8_t kImuInt = 34;    // BNO085 INT (active low), input-only pin
constexpr uint8_t kImuReset = 25;  // BNO085 RST (active low)
constexpr uint8_t kGasAdc =
    35;  // MQ-2 AO through a 10k/15k divider (ADC1, input-only)
// UART2 to the eyes ESP32 (future).
constexpr uint8_t kEyesTx = 17;
constexpr uint8_t kEyesRx = 16;

#else
#error "pins.h: unsupported target (expected ESP32-S3 or ESP32)"
#endif

}  // namespace pins

// I2C addresses (7-bit).
namespace i2c {
constexpr uint8_t kPcaLeft = 0x40;   // servo bus: legs 0, 1, 2
constexpr uint8_t kPcaRight = 0x41;  // servo bus: legs 3, 4, 5
// Sensor bus. Every VL53L0X starts at 0x29; moved at boot via XSHUT.
constexpr uint8_t kVl53l0xDefault = 0x29;
constexpr uint8_t kVl53l0x[4] = {0x30, 0x31, 0x32, 0x33};
constexpr uint8_t kBno085 = 0x4A;
constexpr uint8_t kBme280 = 0x76;
// Same address as kPcaLeft, but on the sensor bus.
constexpr uint8_t kIna226 = 0x40;
}  // namespace i2c

// Servo wiring: PCA9685 channel per [leg % 3][joint]. Legs 0-2 use kPcaLeft,
// legs 3-5 use kPcaRight, with the same layout (one header block per leg).
// Leg order (top view): 0 front-left, 1 middle-left, 2 rear-left,
//                       3 front-right, 4 middle-right, 5 rear-right.
// Joints: 0 coxa, 1 femur, 2 tibia.
namespace servo {
constexpr uint8_t kChannel[3][3] = {
    {0, 1, 2},   // front leg:  channels 0-2  (3 free)
    {4, 5, 6},   // middle leg: channels 4-6  (7 free)
    {8, 9, 10},  // rear leg:   channels 8-10 (11-15 free)
};
}  // namespace servo

}  // namespace hexapod
