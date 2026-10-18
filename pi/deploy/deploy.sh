#!/usr/bin/env bash
# Deploys a release package on the Pi (run as root):
#
#   sudo deploy.sh hexapod-<version>.tar.gz [--bootstrap]
#
# 1. Refuses unless hexd reports the robot SAFE_SIT or RELAXED.
#    --bootstrap skips this only when hexd is not answering at all (first
#    install); a robot that is up and not seated is never updated.
# 2. Extracts the package into releases/<version>.
# 3. If the firmware differs from the running one: keeps the running image in
#    shared/firmware/ (reading the flash if there is no copy) and flashes the
#    new one with esptool through /dev/hexapod-esp32.
# 4. Points `current` at the new release and restarts hexd.
# 5. Verifies within 10 s: /health is 200 and /version shows the new hexd and
#    firmware.
# 6. On failure rolls back: previous `current` and previous firmware.
# 7. Keeps the last 5 releases.
#
# Every external tool can be overridden (tests run this on a PC with fakes).
set -euo pipefail

ROOT=${HEXAPOD_ROOT:-/opt/hexapod}
HEXD_URL=${HEXD_URL:-http://127.0.0.1:8080}
ESP32_PORT=${ESP32_PORT:-/dev/hexapod-esp32}
ESPTOOL=${ESPTOOL:-esptool}
SYSTEMCTL=${SYSTEMCTL:-systemctl}
SERVICE_USER=${SERVICE_USER:-hexapod}
VERIFY_SECONDS=${VERIFY_SECONDS:-10}
KEEP_RELEASES=${KEEP_RELEASES:-5}
FLASH_BAUD=${FLASH_BAUD:-460800}
FLASH_SIZE=${FLASH_SIZE:-0x400000}  # bytes read when backing up an unknown image

log() { printf '[deploy] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

PACKAGE=${1:-}
BOOTSTRAP=0
[[ ${2:-} == --bootstrap ]] && BOOTSTRAP=1
[[ -f $PACKAGE ]] || die "usage: deploy.sh <hexapod-<version>.tar.gz> [--bootstrap]"
for tool in curl jq tar sha256sum flock; do
  command -v "$tool" >/dev/null || die "missing $tool"
done

# One deploy at a time. Children must not inherit the lock (fd 9): a hexd
# started from here would otherwise hold it forever.
mkdir -p "$ROOT/shared"
exec 9>"$ROOT/shared/deploy.lock"
flock -n 9 || die "another deploy is running"
systemctl_() { "$SYSTEMCTL" "$@" 9>&-; }
esptool_() { "$ESPTOOL" "$@" 9>&-; }

http_json() { curl -fsS --max-time 2 "$HEXD_URL$1"; }

# --- 1. robot must be seated ---------------------------------------------------
if status=$(http_json /status 2>/dev/null); then
  state=$(jq -r '.state' <<<"$status")
  case $state in
    SAFE_SIT | RELAXED) log "robot is $state: ok to update" ;;
    "") die "hexd answers but has no telemetry from the ESP32: cannot tell if the robot is seated" ;;
    *) die "robot is $state: sit it down first (only SAFE_SIT or RELAXED)" ;;
  esac
elif ((BOOTSTRAP)); then
  log "hexd not answering: --bootstrap, continuing (first install)"
else
  die "hexd not answering at $HEXD_URL (use --bootstrap only for a first install)"
fi

# --- 2. extract ---------------------------------------------------------------
manifest=$(tar -xzOf "$PACKAGE" --wildcards '*/manifest.json') || die "package has no manifest.json"
VERSION=$(jq -er '.version' <<<"$manifest")
FW_VERSION=$(jq -er '.firmware_version' <<<"$manifest")
FW_CHIP=$(jq -er '.firmware_chip' <<<"$manifest")
[[ $VERSION =~ ^[A-Za-z0-9._-]+$ ]] || die "bad version '$VERSION'"

RELEASE="$ROOT/releases/$VERSION"
PREVIOUS=$(readlink -f "$ROOT/current" 2>/dev/null || true)
[[ $PREVIOUS == "$RELEASE" ]] && die "$VERSION is already the current release"
mkdir -p "$ROOT/releases"
rm -rf "$RELEASE.tmp"
mkdir -p "$RELEASE.tmp"
tar -xzf "$PACKAGE" -C "$RELEASE.tmp" --strip-components=1
(cd "$RELEASE.tmp" && jq -r '"\(.firmware_sha256)  firmware/firmware.bin\n\(.hexd_sha256)  bin/hexd"' manifest.json |
  sha256sum -c --quiet) || die "package checksum mismatch"
rm -rf "$RELEASE"
mv "$RELEASE.tmp" "$RELEASE"
chown -R "$SERVICE_USER:$SERVICE_USER" "$RELEASE" 2>/dev/null || true
log "extracted $VERSION"

# --- 3. firmware --------------------------------------------------------------
running_fw=$(http_json /version 2>/dev/null | jq -r '.firmware_version // empty' || true)
FIRMWARE_DIR="$ROOT/shared/firmware"
mkdir -p "$FIRMWARE_DIR"
flashed=0
backup=""

flash() { # image
  esptool_ --chip "$FW_CHIP" --port "$ESP32_PORT" --baud "$FLASH_BAUD" write-flash 0x0 "$1" >&2
}

if [[ $running_fw != "$FW_VERSION" ]]; then
  log "firmware ${running_fw:-unknown} -> $FW_VERSION"
  systemctl_ stop hexd # frees the serial port
  if [[ -n $running_fw ]]; then
    backup="$FIRMWARE_DIR/$running_fw.bin"
    if [[ ! -f $backup ]]; then
      if [[ -n $PREVIOUS && -f $PREVIOUS/firmware/firmware.bin &&
        $(jq -r '.firmware_version' "$PREVIOUS/manifest.json" 2>/dev/null) == "$running_fw" ]]; then
        cp "$PREVIOUS/firmware/firmware.bin" "$backup"
      else
        log "no copy of $running_fw: reading the flash (takes a while)"
        esptool_ --chip "$FW_CHIP" --port "$ESP32_PORT" --baud "$FLASH_BAUD" \
          read-flash 0x0 "$FLASH_SIZE" "$backup.tmp" >&2 && mv "$backup.tmp" "$backup"
      fi
    fi
  fi
  flash "$RELEASE/firmware/firmware.bin" || {
    log "flash failed"
    [[ -n $backup ]] && flash "$backup" || true
    systemctl_ start hexd
    die "firmware not updated; previous firmware restored"
  }
  flashed=1
  cp "$RELEASE/firmware/firmware.bin" "$FIRMWARE_DIR/$FW_VERSION.bin"
else
  log "firmware already $FW_VERSION"
fi

# --- 4. switch ----------------------------------------------------------------
switch_to() { # release dir
  ln -sfn "$1" "$ROOT/current.new"
  mv -T "$ROOT/current.new" "$ROOT/current"
  systemctl_ restart hexd
}
switch_to "$RELEASE"
log "current -> $VERSION, hexd restarted"

# --- 5. verify ----------------------------------------------------------------
verify() { # hexd_version firmware_version
  local deadline=$((SECONDS + VERIFY_SECONDS)) v
  while ((SECONDS < deadline)); do
    if http_json /health >/dev/null 2>&1 && v=$(http_json /version 2>/dev/null) &&
      [[ $(jq -r '.hexd_version' <<<"$v") == "$1" && $(jq -r '.firmware_version' <<<"$v") == "$2" ]]; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

if verify "$VERSION" "$FW_VERSION"; then
  log "verified: hexd and firmware $VERSION, /health ok"
else
  # --- 6. rollback -------------------------------------------------------------
  log "verification failed within ${VERIFY_SECONDS}s: rolling back"
  if ((flashed)) && [[ -n $backup && -f $backup ]]; then
    systemctl_ stop hexd
    flash "$backup" || log "could not restore the previous firmware!"
  fi
  if [[ -n $PREVIOUS ]]; then
    switch_to "$PREVIOUS"
    prev_version=$(basename "$PREVIOUS")
    if verify "$prev_version" "${running_fw:-}"; then
      log "rolled back to $prev_version"
    else
      log "rollback to $prev_version did not verify either: check the robot"
    fi
  else
    systemctl_ stop hexd
    log "no previous release: hexd stopped"
  fi
  exit 1
fi

# --- 7. prune -----------------------------------------------------------------
current=$(readlink -f "$ROOT/current")
mapfile -t old < <(ls -1dt "$ROOT"/releases/*/ 2>/dev/null | sed 's:/$::' | tail -n +$((KEEP_RELEASES + 1)))
for dir in "${old[@]}"; do
  [[ $dir == "$current" || $dir == "$PREVIOUS" ]] && continue
  rm -rf "$dir"
  log "removed old release $(basename "$dir")"
done
log "done"
