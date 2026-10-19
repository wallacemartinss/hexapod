# Controller pinout

**English** · [Português](PINOUT.pt-BR.md)

Every ESP32 pin and what it does, for both boards. The code's source of truth is [`include/pins.h`](include/pins.h): **change it here, change it there** (and the other way round).

| Board | Use | PlatformIO environment |
|---|---|---|
| ESP32-S3 SuperMini | The robot | `esp32s3` |
| ESP32 DevKit, 38 pins (ESP-WROOM-32) | Bench tests, temporary | `esp32dev` |

## Signals (the same on both boards)

| Signal | Direction | Goes to | What for |
|---|---|---|---|
| `SERVO_SDA` / `SERVO_SCL` | I2C 0, 400 kHz | SDA/SCL of **both** PCA9685 | Servo bus |
| `SENSOR_SDA` / `SENSOR_SCL` | I2C 1 | SDA/SCL of the 4 VL53L0X, BNO085, BME280, INA226 | Sensor bus |
| `PCA_OE` | Output | OE of **both** PCA9685 (in parallel) | **Emergency cut.** High = no pulse on any servo |
| `XSHUT0..3` | Output | XSHUT of each VL53L0X | Turns the sensors on one at a time at boot to move them from 0x29 to 0x30–0x33 |
| `IMU_INT` | Input | BNO085 INT | New reading ready (active low) |
| `IMU_RST` | Output | BNO085 RST | Resets the IMU if it hangs (active low) |
| `LED_DATA` | Output | DIN of the first WS2812 | The two headlights, one on each side of the camera |
| `EYES_TX` / `EYES_RX` | — | **Free** | Reserved for an eyes' ESP32 that is no longer planned: the eye is on the Pi |
| USB | — | Raspberry Pi | Protocol (COBS + CRC16 + nanopb) and firmware flashing |

## ESP32-S3 SuperMini (the robot)

| GPIO | Signal | Notes |
|---|---|---|
| 1 | `PCA_OE` | Needs an external pull-up (see below) |
| 2 | `LED_DATA` | |
| 4 | `SERVO_SDA` | |
| 5 | `SERVO_SCL` | |
| 6 | `SENSOR_SDA` | |
| 7 | `SENSOR_SCL` | |
| 8 | `XSHUT0` | VL53L0X **front** → 0x30 |
| 9 | `XSHUT1` | VL53L0X **right** → 0x31 |
| 14 | `XSHUT2` | VL53L0X **rear** → 0x32 (moved off GPIO10 to free an ADC1 pin) |
| 11 | `XSHUT3` | VL53L0X **left** → 0x33 |
| 12 | `IMU_INT` | |
| 13 | `IMU_RST` | |
| 10 | `GAS_AO` | MQ-2 analog output, **through the 10 kΩ/15 kΩ divider** (see below). ADC1 |
| 43 | (free) | Was `EYES_TX`. Carries the ROM log at boot: fine for a debug UART |
| 44 | (free) | Was `EYES_RX` |
| 48 | On-board RGB LED | Firmware status |
| 0 | — | BOOT button, do not use |
| 3 | — | Strapping pin, free but avoided |
| 19, 20 | — | Native USB, **off limits** |

> **To check when the board arrives:** whether the SuperMini bought exposes GPIO1–13, 43 and 44 on those pads. The 14 signals use every safe GPIO available; no pin is left over.

## ESP32 DevKit, 38 pins, ESP-WROOM-32 (bench)

| GPIO | Signal | Notes |
|---|---|---|
| 27 | `PCA_OE` | Needs an external pull-up (see below) |
| 23 | `LED_DATA` | |
| 21 | `SERVO_SDA` | The board's default I2C |
| 22 | `SERVO_SCL` | |
| 32 | `SENSOR_SDA` | |
| 33 | `SENSOR_SCL` | |
| 18 | `XSHUT0` | VL53L0X **front** → 0x30 |
| 19 | `XSHUT1` | VL53L0X **right** → 0x31 |
| 13 | `XSHUT2` | VL53L0X **rear** → 0x32 |
| 14 | `XSHUT3` | VL53L0X **left** → 0x33. Toggles at boot (harmless: it only resets the sensor) |
| 34 | `IMU_INT` | Input-only pin, ideal for an interrupt |
| 25 | `IMU_RST` | |
| 35 | `GAS_AO` | MQ-2 analog output, **through the 10 kΩ/15 kΩ divider**. ADC1, input only |
| 17 | (free) | Was `EYES_TX` (UART2) |
| 16 | (free) | Was `EYES_RX` (UART2) |
| 1, 3 | USB (CP2102) | UART0 = the link to the Pi. **Do not use** |
| 6–11 | — | Flash memory, **off limits** (SD0–SD3, CMD, CLK on the board) |
| 0, 2, 5, 12, 15 | — | Strapping pins: they affect boot, avoided |
| 4, 26, 36 (VP), 39 (VN) | free | 36/39 are input only |

## Raspberry Pi: GPS, the eye and the OLED screen

They live on the Pi, not on the ESP32: the ESP32's serial frame is full (250 of 254 bytes), GPS is not real time, and only the Pi knows the IP, the network and whether an app is connected (so the screen can show the pairing QR code). Turned on by Ansible (`enable_i2c`, `enable_gps_uart`).

| Module | Module pin | Pi physical pin | Notes |
|---|---|---|---|
| SSD1306 0.96" OLED (I2C, 0x3C) | VCC | 1 (3.3 V) | |
| | GND | 9 | |
| | SDA | 3 (GPIO2) | `/dev/i2c-1` |
| | SCL | 5 (GPIO3) | |
| ST7789 1.54" eye (SPI, 240×240) | VCC | 1 (3.3 V) | Takes the OLED's place (the eye replaces it) |
| | GND | 20 | |
| | SCL / SCK | 23 (GPIO11, SPI0 SCLK) | |
| | SDA / MOSI | 19 (GPIO10, SPI0 MOSI) | |
| | CS | 24 (GPIO8, SPI0 CE0) | Many 1.54" boards have no CS pin: then SPI mode 3 |
| | DC | 22 (GPIO25) | Data / command |
| | RES | 18 (GPIO24) | Reset |
| | BLK | 12 (GPIO18) | Backlight (PWM: brightness) |
| GY-NEO6MV2 GPS (UART, 9600) | VCC | 17 (3.3 V) | The module takes 3.3–5 V |
| | GND | 14 | |
| | TX | 10 (GPIO15, the Pi's RX) | `/dev/serial0` |
| | RX | 8 (GPIO14, the Pi's TX) | Optional: only to configure the GPS |

Pins 2 and 4 (5 V) and 6 (GND) power the Pi from the Mini560 on the robot. **Plug and unplug modules with the Pi off.** The same pins on a Pi 3 and a Pi 4.

- **GPS:** it only gets a position (fix) with open sky. The first fix can take minutes; the module's backup battery keeps the almanac for the next ones.
- **Check:** `ssh <you>@hexapod.local 'bash -s' < pi/provision/check.sh` (OLED and GPS sections).

## MQ-2 (gas and smoke)

The module runs on **5 V** (Mini560) and its heater draws **~150 mA**. The analog output `AO` swings from 0 to **5 V**, but an ESP32 pin takes 3.3 V at most. So **never wire `AO` straight in**:

```
AO ──[10 kΩ]──┬── GAS_AO (GPIO10 on the S3, GPIO35 on the bench board)
              │
           [15 kΩ]
              │
             GND
```

With 5 V on `AO`, the pin sees 3.0 V. The digital output `DO` (the module's comparator, also 5 V) is not used: the firmware raises the alarm by comparing with clean air.

- **Warm-up:** a few minutes at every start (the firmware ignores the alarm for the first 3) and **24–48 h** powered the very first time, for the sensor to settle.
- **Relative reading:** the level is a percentage of the ADC range, not ppm. The alarm goes off when the level climbs well above the clean-air baseline (`config.h`, MQ-2 block).
- While `config::kGasSensorFitted` is `false`, the firmware does not even read the pin and reports `FAULT_GAS_SENSOR`.

## Servos: the channel of each joint

PCA9685 no. 1 (**0x40**) = the **left** legs; no. 2 (**0x41**) = the **right** legs. Both boards use the same layout: **one block of 4 connectors per leg**, leaving the 4th free.

```
Top view               PCA 0x40 (left)           PCA 0x41 (right)
     FRONT             ch.    leg    joint       ch.    leg    joint
  0 \      / 3          0     0      coxa         0     3      coxa
     \____/             1     0      femur        1     3      femur
  1 --|  |-- 4          2     0      tibia        2     3      tibia
     /|__|\             4     1      coxa         4     4      coxa
  2 /      \ 5          5     1      femur        5     4      femur
                        6     1      tibia        6     4      tibia
                        8     2      coxa         8     5      coxa
                        9     2      femur        9     5      femur
                       10     2      tibia       10     5      tibia
```

Free channels: 3, 7, 11–15 on each board. Each servo's direction, offset and limits are **not** set here: they are calibrated and stored in NVS.

## I2C addresses

| Bus | Device | Address |
|---|---|---|
| I2C 0 (servos) | Left PCA9685 | 0x40 (factory jumpers) |
| I2C 0 (servos) | Right PCA9685 | **0x41**: solder jumper **A0** |
| I2C 1 (sensors) | VL53L0X front/right/rear/left | 0x30/0x31/0x32/0x33 (changed at boot; all 0x29 from the factory) |
| I2C 1 | BNO085 | 0x4A |
| I2C 1 | BME280 | 0x76 |
| I2C 1 | INA226 | 0x40 (no clash with the PCA: another bus) |

## Wiring precautions

### PCA9685 OE: pull-up required

The project's safe default is **servos off**. But on Adafruit-compatible boards (like the HW-170), OE comes with a resistor to GND, which **turns the outputs on** while the ESP32 is in reset and the pin floats.

- Wire a **1 kΩ resistor between `PCA_OE` and 3.3 V**.
- With both boards in parallel (2 × 10 kΩ to GND = 5 kΩ), OE sits at ~2.75 V, above the PCA9685's minimum high level (0.7 × 3.3 V = 2.31 V). A larger resistor (4.7 kΩ or 10 kΩ) does **not** guarantee a high level.
- **Check with a multimeter**, with the ESP32 disconnected: OE must read ≥ 2.5 V.

Consequence: after an ESP32 reset, the servos have **no torque** until the firmware reads the PCA9685s and enables OE again. That follows safety rule no. 1; the robot should be resting or sitting.

### Power

| Rail | From | To |
|---|---|---|
| 6.0 V (servos) | 20 A step-down | **V+** terminal of both PCA9685 (never VCC) |
| 5 V (logic) | Mini560 | Pi (GPIO pins 2/6), ESP32 5 V, WS2812 |
| 3.3 V | ESP32 regulator | **VCC** of the PCA9685s and of every sensor |
| GND | **Common to everything** | Battery, step-down, Mini560, ESP32, Pi, PCA9685, sensors |

- PCA9685 VCC at **3.3 V** keeps I2C at the ESP32's level, no level shifter needed.
- Each sensor board carries its own I2C pull-ups, and the sensor bus has 7 in parallel. At 10 kΩ each that is ~1.4 kΩ in total, within the limit (about 1 kΩ minimum at 3.3 V). Boards with 4.7 kΩ can go past it: **with everything off, measure the resistance between SDA and 3.3 V**. Below 1 kΩ, remove the pull-ups from some boards.
- The DevKit's 3.3 V (AMS1117) gives ~600 mA in total: enough for the sensors, but **never** power servos or LEDs from it.

### WS2812

- Power at 5 V; data at 3.3 V works with most strips but is out of spec. If the first LED glitches, use a level shifter (74AHCT125) or a 330 Ω resistor in series on the data line.
- WS2812 vs. 1 W LEDs is still undecided.

### INA226

The factory shunt (0.1 Ω) only measures up to ~0.8 A. Read the shunt note in the [parts list](../README.md#parts-list) before trusting the current.
