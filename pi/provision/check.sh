#!/usr/bin/env bash
# Validate a provisioned hexapod Pi (Phase 1.3). Runs ON the Pi:
#   ssh wallace@hexapod.local 'bash -s' < pi/provision/check.sh
# Exit code: number of FAILs (WARNs do not fail).
set -uo pipefail

fails=0
ok()   { printf '  \e[32mOK\e[0m    %s\n' "$*"; }
warn() { printf '  \e[33mWARN\e[0m  %s\n' "$*"; }
fail() { printf '  \e[31mFAIL\e[0m  %s\n' "$*"; fails=$((fails + 1)); }

echo "== Power"
throttled=$(vcgencmd get_throttled | cut -d= -f2)
if [[ $throttled == 0x0 ]]; then
  ok "get_throttled = 0x0"
elif (( throttled & 0x1 )); then
  fail "get_throttled = $throttled: UNDERVOLTAGE NOW (check cable/supply)"
else
  warn "get_throttled = $throttled: undervoltage/throttling happened since boot"
fi

echo "== Camera"
if rpicam-hello --list-cameras 2>&1 | grep -qi ov5647; then
  ok "OV5647 detected"
else
  fail "OV5647 not listed by rpicam-hello (try camera_force_ov5647: true)"
fi

echo "== Microphone"
if arecord -l 2>/dev/null | grep -qi usb; then
  ok "USB capture device: $(arecord -l | grep -i usb | head -1)"
  mic=$(grep -oP '^MIC_DEVICE=\K.*' /opt/hexapod/shared/config/mic.env 2>/dev/null)
  if arecord -L 2>/dev/null | grep -qxF "$mic"; then
    ok "MIC_DEVICE=$mic exists"
  else
    warn "MIC_DEVICE=$mic not in 'arecord -L'; set mic_alsa_device"
  fi
else
  fail "no USB microphone in 'arecord -l'"
fi

echo "== ESP32"
if [[ -e /dev/hexapod-esp32 ]]; then
  ok "$(ls -l /dev/hexapod-esp32)"
else
  warn "/dev/hexapod-esp32 absent (ESP32 not connected?)"
fi

echo "== OLED (I2C)"
if [[ ! -e /dev/i2c-1 ]]; then
  fail "/dev/i2c-1 absent (enable_i2c, then reboot)"
# -r: probe with a read. Some SSD1306 clones ignore i2cdetect's default
# quick-write probe and look absent. Output captured first: with pipefail,
# grep -q quitting early would SIGPIPE i2cdetect and turn a match into a miss.
elif bus=$(i2cdetect -y -r 1 2>/dev/null) && grep -qE '^30:.* 3c' <<<"$bus"; then
  ok "SSD1306 answers at 0x3C"
else
  warn "nothing at 0x3C (OLED not wired? some boards use 0x3D)"
fi

echo "== GPS (UART)"
if [[ ! -e /dev/serial0 ]]; then
  fail "/dev/serial0 absent (enable_gps_uart, then reboot)"
else
  stty -F /dev/serial0 9600 raw -echo 2>/dev/null
  nmea=$(timeout 3 cat /dev/serial0 2>/dev/null | tr -d '\r' | grep -m1 -aE '^\$G[PN]RMC')
  if [[ -z $nmea ]]; then
    warn "no NMEA on /dev/serial0 in 3 s (GPS not wired? TX of the GPS goes to pin 10)"
  elif [[ $(cut -d, -f3 <<<"$nmea") == A ]]; then
    ok "GPS has a fix: $nmea"
  else
    warn "GPS talking, no fix yet (needs open sky; first fix can take minutes)"
  fi
fi

echo "== Read-only root"
if ! command -v hexapod-readonly >/dev/null; then
  warn "hexapod-readonly not installed (ansible --tags readonly)"
elif findmnt -no FSTYPE / | grep -q overlay; then
  ok "root is read-only; /opt/hexapod on $(findmnt -no SOURCE /opt/hexapod 2>/dev/null || echo '?')"
elif mountpoint -q /opt/hexapod; then
  warn "root is writable (sudo hexapod-readonly on && sudo reboot to protect the card)"
else
  warn "root is writable and /opt/hexapod has no partition of its own (make-data-partition.sh)"
fi

echo "== Tailscale"
if tailscale status >/dev/null 2>&1; then
  ok "tailscale up: $(tailscale ip -4 2>/dev/null | head -1)"
else
  warn "tailscale not logged in (sudo tailscale up)"
fi

echo "== Services"
for svc in mediamtx mic-stream; do
  if systemctl is-active --quiet "$svc"; then ok "$svc active"; else fail "$svc $(systemctl is-active "$svc")"; fi
done
if [[ -x /opt/hexapod/current/bin/hexd ]]; then
  if systemctl is-active --quiet hexd; then ok "hexd active"; else fail "hexd $(systemctl is-active hexd)"; fi
else
  warn "hexd not deployed yet"
fi

echo "== Watchdog"
wd=$(systemctl show -p RuntimeWatchdogUSec --value)
if [[ $wd != 0 && $wd != infinity ]]; then ok "RuntimeWatchdog = $wd"; else fail "hardware watchdog disabled"; fi

echo "== Streams"
if paths=$(curl -fsS http://127.0.0.1:9997/v3/paths/list 2>/dev/null); then
  for p in cam mic; do
    if jq -e --arg p "$p" '.items[] | select(.name == $p and .ready)' <<<"$paths" >/dev/null; then
      ok "path $p ready"
    else
      fail "path $p not ready"
    fi
  done
else
  fail "MediaMTX API not answering on 127.0.0.1:9997"
fi
ip=$(hostname -I | awk '{print $1}')
echo "  Open in the PC browser: http://hexapod.local:8889/cam  (or http://$ip:8889/cam)"

echo
if (( fails == 0 )); then echo "All checks passed."; else echo "$fails check(s) failed."; fi
exit "$fails"
