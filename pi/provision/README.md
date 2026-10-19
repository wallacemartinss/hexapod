# Raspberry Pi setup (Ansible)

**English** · [Português](README.pt-BR.md)

This playbook turns a stock Raspberry Pi OS Lite into the robot's "brain". It is **idempotent**: run it as many times as you like, it only changes what differs. It is the same playbook that builds the ready-made SD card image (`pi/image/build-image.sh`, in `image_build` mode), so the maker path and the simple path end up with the same system.

## What Ansible is (if you never used it)

[Ansible](https://docs.ansible.com) runs **on your PC** and sets up another machine **over the network, through SSH**. Nothing gets installed on the Pi beyond what the playbook asks for. Instead of a list of commands to copy and paste, the playbook describes **how the Pi should be** ("this package installed", "this line in `config.txt`", "this service on"). Ansible checks each item and only touches what differs. That makes it:

- **Repeatable:** a new Pi ends up the same as the last one, with no step forgotten.
- **Safe to run again:** after updating the code, just run it again; what is already right stays as it is.
- **Readable:** each step is a short YAML file in `tasks/`, with the reason in a comment.

## Requirements

- A Pi flashed with **Raspberry Pi OS Lite (64-bit)**, with hostname `hexapod`, your user and **SSH key** (see the [maker guide](../../docs/maker-install.md#1-flash-raspberry-pi-os)).
- `ssh hexasys@hexapod.local` working from the PC.
- Ansible on the PC: `pipx install ansible-core` or your distribution's package (`ansible --version`).

## Use

```bash
cd pi/provision
ansible-playbook site.yml --check --diff   # dry run: shows what would change, touches nothing
ansible-playbook site.yml                  # apply (reboots the Pi if a boot setting changed)
ansible-playbook site.yml --tags mediamtx  # only one part (tags below)
ansible-playbook site.yml -e ansible_host=10.0.0.86               # no mDNS: by IP
```

Two users live on the Pi: **`hexasys`**, the admin you log in with (made when flashing the card), and **`hexapod`**, the service user that runs hexd with no login and only the permissions it needs. The inventory (`inventory.yml`) logs in as `hexasys@hexapod.local`; another admin name: `HEXAPOD_SSH_USER=<name>` in your environment (or `-e ansible_user=<name>`), another address: `-e ansible_host=<ip>`.

**Check** (runs on the Pi: camera, microphone, power, ESP32, screen, GPS and Tailscale):

```bash
ssh hexasys@hexapod.local 'bash -s' < check.sh
```

**Tailscale:** the auth key never goes into the repository. The simplest way is from the app (Settings → Remote access). From the playbook:

```bash
TS_AUTHKEY=tskey-... ansible-playbook site.yml --tags tailscale -e tailscale_authkey="$TS_AUTHKEY"
```

## What the playbook does

| Part | Tag | Details |
|---|---|---|
| Packages | `base` | `apt dist-upgrade` (off with `apt_upgrade: false`), `rpicam-apps`, `alsa-utils`, `ffmpeg`, `avahi-daemon` (+ the `_hexapod._tcp` announcement the app looks for), `i2c-tools`, `jq`, `polkitd`; `esptool` from PyPI at a pinned version in `/opt/esptool` (Debian's package lacks the stub flasher) |
| Boot | `boot` | Camera (`camera_auto_detect=1`, or `dtoverlay=ov5647`), **I2C** (OLED screen), **SPI** (ST7789 eye), the GPS **UART** with no serial console, the Wi-Fi country (`regdom`) and power savings. **Reboots the Pi** if anything changed |
| Layout | `layout` | Service user `hexapod` (groups `dialout`, `video`, `audio`, `i2c`, `spi`, `gpio`), `/opt/hexapod/{releases,shared/{config,logs,firmware}}`, `hexd.yaml` (only if missing) and **minimal** polkit rules: power off the Pi (critical battery), drive the Wi-Fi through NetworkManager and restore the Tailscale operator |
| udev | `udev` | ESP32-S3 `303a:1001` → `/dev/hexapod-esp32`, ignored by ModemManager; plugging a board in flashes the firmware if it does not have the hexapod's. **Temporary:** classic DevKit IDs for the bench (`esp32_test_usb_ids`) |
| Tailscale | `tailscale` | Official repository; `tailscale up` only with `tailscale_authkey` |
| MediaMTX | `mediamtx` | arm64 binary at a pinned version (`mediamtx_version`), checksum verified; config in `pi/mediamtx/mediamtx.yml` |
| Services | `services` | `hexd`, `mediamtx`, `mic-stream`, the boot screen, automatic ESP32 flashing, Wi-Fi unblocking and the Tailscale operator. `hexd` starts after the first deploy |
| Watchdog | `watchdog` | `RuntimeWatchdogSec=14s`: if the system hangs, the chip reboots the Pi |
| Read-only | `readonly` | Root as an overlay with `/opt/hexapod` on its own partition (below); only with `readonly_root: true` |

Every option lives in [`group_vars/all.yml`](group_vars/all.yml), with comments.

### Power savings

Each one needs a reboot.

| Option | Effect | Why it can go |
|---|---|---|
| `disable_bluetooth` | `dtoverlay=disable-bt` | The robot does not use Bluetooth, and it frees the good UART for the GPS |
| `disable_onboard_audio` | `dtparam=audio=off` | The microphone is USB and the Pi has no speaker |
| `disable_hdmi` | `video=HDMI-A-1:d` and `HDMI-A-2:d` in `cmdline.txt` | No monitor on the robot (a Pi 4 has two outputs). To debug with a monitor, set `false` and run again |

## Read-only (protecting the SD card)

With a read-only root the system runs on a layer in RAM (`overlayroot`): cutting the power any way you like never corrupts the card, and system changes vanish at reboot. What must persist lives on its **own writable partition**: `/opt/hexapod` (releases, settings, the previous firmware, the camera gallery, the pairing key) and the Tailscale login.

**Once, with the card in the PC** (make a backup image of the card first):

```bash
lsblk                                              # find the card (e.g. /dev/sdb, partitions bootfs and rootfs)
sudo pi/provision/make-data-partition.sh /dev/sdX  # root shrinks to 24 GB, "hexdata" takes the rest
```

The script checks it is a Pi card (labels `bootfs`/`rootfs`, removable, nothing mounted), shows the plan and only goes on after you type **SIM** (yes). Nothing is erased: the old `/opt/hexapod` stays in `/opt/hexapod.before-data`.

**Then, with the card back in the Pi:**

```bash
ansible-playbook site.yml --tags readonly -e readonly_root=true   # turns it on and reboots
```

**Day to day, on the Pi:**

| Command | What for |
|---|---|
| `hexapod-readonly status` | How it is now and at the next boot |
| `sudo hexapod-readonly off && sudo reboot` | **Before** `apt`, Ansible or any system change |
| `sudo hexapod-readonly on && sudo reboot` | Protect it again |

- The playbook **refuses to run** on a read-only root (the changes would vanish).
- `deploy.sh` keeps working: it only writes to `/opt/hexapod`.
- Do not use `raspi-config`'s overlay option: it freezes `/opt/hexapod` too (it lacks `recurse=0`).
- Logs live in RAM (up to 32 MB) and vanish at reboot.

## Hardware to-dos

- `mic_alsa_device`: confirm the name with `arecord -L` once the USB microphone is plugged in.
- `esp32_test_usb_ids`: empty it when the ESP32-S3 arrives.
