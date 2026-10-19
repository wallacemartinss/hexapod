#!/usr/bin/env bash
# Flashes the ESP32 with the installed release's firmware when it needs it:
# once after a fresh SD image (marker file), or whenever the board has no
# hexapod firmware at all (blank or foreign: no Hello within 10 s). A board
# that already runs hexapod firmware - possibly a maker's own build - is
# left alone. Run by udev when the ESP32 is plugged in, and at boot.
# Flashing never moves a servo (the firmware boots with outputs off).
set -euo pipefail

ROOT=${HEXAPOD_ROOT:-/opt/hexapod}
PORT=${ESP32_PORT:-/dev/hexapod-esp32}
MARK=$ROOT/shared/firmware/flash-on-first-boot
MANIFEST=$ROOT/current/manifest.json

[[ -e $PORT && -f $MANIFEST ]] || exit 0
want=$(jq -r .firmware_version "$MANIFEST")
chip=$(jq -r .firmware_chip "$MANIFEST")

have=""
for _ in $(seq 1 10); do # hexd takes a moment to meet a board just plugged in
  have=$(curl -fsS --max-time 2 http://127.0.0.1:8080/version 2>/dev/null | jq -r '.firmware_version // empty' || true)
  [[ -n $have ]] && break
  sleep 1
done

if [[ $have == "$want" ]]; then
  rm -f "$MARK"
  exit 0
fi
if [[ -n $have && ! -e $MARK ]]; then
  echo "board runs hexapod firmware $have (not $want): left alone; deploy.sh updates it"
  exit 0
fi

echo "flashing firmware $want (board had: ${have:-no hexapod firmware})"
systemctl stop hexd
trap 'systemctl start hexd' EXIT
esptool --chip "$chip" --port "$PORT" --baud 460800 write-flash 0x0 "$ROOT/current/firmware/firmware.bin"
rm -f "$MARK"
