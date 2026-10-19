# Maker install

**English** · [Português](instalacao-maker.md)

Building the robot's software yourself, from a stock Raspberry Pi OS to a robot you can drive, with every step in your hands. If you just want it working, the ready-made image is quicker: [`install.md`](install.md). Both end in the same place, and you can switch between them at any time.

## What you need

**On your PC (Linux or macOS; Windows through WSL)**

| Tool | For | Check |
|---|---|---|
| `git` | the code | `git --version` |
| Go 1.25+ | `hexd` (the Pi service) | `go version` |
| PlatformIO Core | the ESP32 firmware | `pio --version` |
| `buf` + `protoc-gen-go` + nanopb | generated protocol code | `buf --version` |
| Ansible | preparing the Pi | `ansible --version` |
| Raspberry Pi Imager | the card | |
| Flutter 3.41+ (optional) | building the app yourself | `flutter --version` |

Install the protocol tools with `go install github.com/bufbuild/buf/cmd/buf@v1.74.0`, `go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.12` and `pip install nanopb==0.4.9.1`, and keep `~/go/bin` on your `PATH`.

**Hardware:** the robot from the [parts list](../README.md#parts-list), a microSD card (16 GB or more) and **proper power**: under-voltage takes the Pi's Wi-Fi down. Check it any time in the app (Data → Raspberry Pi) or with `vcgencmd get_throttled` (it must be `0x0`).

```bash
git clone https://github.com/wallacemartinss/hexapod.git
cd hexapod
```

## 1. Flash Raspberry Pi OS

In Raspberry Pi Imager: **Raspberry Pi OS Lite (64-bit)**, then *Edit settings*:

- hostname `hexapod`;
- your user and password;
- **SSH with your public key** (*Services → Allow public-key authentication only*);
- your Wi-Fi (a Pi 3 only sees 2.4 GHz) and country.

Boot the Pi and check you can get in: `ssh <you>@hexapod.local`. No mDNS on your network? Use its IP everywhere below.

## 2. Prepare the Pi with Ansible

The playbook installs and configures everything: camera, MediaMTX (video and audio), the `hexd` service and its user, the ESP32 udev rule, I2C (screen), UART (GPS), Tailscale, the hardware watchdog and the power savings. It is safe to run again: it only changes what differs.

```bash
cd pi/provision
ansible-playbook site.yml -e ansible_user=<you> --check --diff   # dry run: shows what would change
ansible-playbook site.yml -e ansible_user=<you>                  # apply (reboots when boot settings change)
ssh <you>@hexapod.local 'bash -s' < check.sh                     # validation
```

`check.sh` lists the camera, the microphone, the power state, the ESP32, the OLED (0x3C), the GPS and Tailscale. Fix what it flags before going on. Details and options: [`pi/provision/README.md`](../pi/provision/README.md).

## 3. Build and install the software

One package carries `hexd` and the ESP32 firmware, built for your board (`esp32s3` for the robot, `esp32dev` for a classic ESP32 on the bench):

```bash
BOARD=esp32s3 pi/deploy/package.sh            # → dist/hexapod-<version>.tar.gz
scp dist/hexapod-<version>.tar.gz <you>@hexapod.local:/tmp/
ssh <you>@hexapod.local
cd /tmp && tar -xzf hexapod-<version>.tar.gz --wildcards '*/deploy.sh' --strip-components=1
sudo bash ./deploy.sh /tmp/hexapod-<version>.tar.gz --bootstrap
```

`--bootstrap` is only for this **first** install (there is no `hexd` answering yet). From then on, leave it out: the deploy then refuses to run unless the robot is sitting or relaxed, flashes the ESP32, restarts `hexd`, checks both versions answer within 10 s and **rolls back** otherwise. It keeps the last 5 versions.

Check: `curl http://hexapod.local:8080/version` shows the same version for `hexd` and the firmware, and the small screen shows the robot's status pages.

## 4. Install the app and pair

- **App:** the APK from the project's Releases page, or build it: `cd app && make install` (phone on USB, USB debugging on).
- **Pairing:** with no app connected, the robot's screen shows a QR code and a 5-character code: in the app, **Pair a robot** and scan it. Without the screen, get the long key from a terminal:

```bash
sudo -u hexapod /opt/hexapod/current/bin/hexd -pairing   # prints the key and a QR (HXP1 <id> <key>)
```

Type `HXP1 <id> <key>` in the pairing screen instead of the short code. The command-line tools need the same key (`-token` or `HEXAPOD_TOKEN`).

## 5. Remote access (optional)

Drive it from anywhere through Tailscale: set it up from the app ([step by step](remote-access.md)) or from a terminal:

```bash
ssh <you>@hexapod.local 'sudo tailscale up --hostname=hexapod'   # opens a login link
```

## 6. Protect the SD card (optional)

A read-only root means pulling the power never corrupts the card; `/opt/hexapod` (releases, settings, pairing key) moves to its own partition. It needs the card in your PC once, to split it: [`pi/provision/README.md`](../pi/provision/README.md#read-only-protecting-the-sd-card).

## Keeping it up to date

- **New version:** repeat step 3 without `--bootstrap`, with the robot sitting.
- **Pi settings:** pull the code and run the playbook again.
- **Firmware only, by hand:** `cd firmware && pio run -e esp32s3 -t upload` with the ESP32 on your PC's USB.

## Looking inside

| What | Where |
|---|---|
| `hexd` log | `journalctl -u hexd -f` |
| Metrics (Prometheus) | `http://hexapod.local:8080/metrics` |
| Health, version | `/health`, `/version`, `/status` |
| Video in a browser | `http://hexapod.local:8889/cam` |
| Live telemetry from your PC | `cd pi && go run ./cmd/hexctl -url ws://hexapod.local:8080/ws -token <key> watch` |
| No robot at all | `hexsim` simulates the ESP32: see [`app/README.md`](../app/README.md) |

## When something goes wrong

| What happens | Likely cause | What to do |
|---|---|---|
| `check.sh` warns about throttling | Weak supply | 5.1 V / 2.5 A supply on the bench (3 A for a Pi 4); Mini560 set to 5.1 V on the robot |
| `/dev/hexapod-esp32` missing | Charge-only cable, or another ESP32 | A data cable; `lsusb` must show `303a:1001` (S3) or `10c4:ea60` (bench board) |
| Deploy: `robot is NORMAL: sit it down first` | Robot standing | Sit it from the app and run again |
| Deploy: `verification failed ... rolling back` | The new version did not come up in 10 s | It already rolled back; read `journalctl -u hexd -b` |
| The app says the robot refused the key | Paired before a reinstall (new key) | Pair again |
| OLED missing in `check.sh` | Wiring, or I2C off | SDA → pin 3, SCL → pin 5, `i2cdetect -r -y 1` must show `3c` |
