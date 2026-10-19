#!/usr/bin/env bash
# Builds the robot's SD card image: Raspberry Pi OS Lite (base.env) + the
# provisioning playbook (image_build=true) + a release package, ready for
# Raspberry Pi Imager ("Use custom"). Runs on Linux as root; on a non-ARM
# host it needs qemu-user with binfmt (Ubuntu: qemu-user-binfmt).
#
#   sudo pi/image/build-image.sh dist/hexapod-<version>.tar.gz [out_dir]
#
# Works on a copy of the image in a temporary directory: no real disk is
# touched. Nothing personal goes in: no user, no password, no SSH keys
# (generated on first boot), no machine-id; the pairing identity is created
# by hexd on first boot, unique per robot.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PI=$(dirname "$HERE")
PACKAGE=${1:?usage: build-image.sh <hexapod-version.tar.gz> [out_dir]}
OUT=${2:-$(dirname "$PACKAGE")}
CACHE=${CACHE:-/var/cache/hexapod-image}
GROW_GB=${GROW_GB:-2} # room for the packages the playbook adds
# shellcheck source=base.env
source "$HERE/base.env"

log() { printf '[image] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[[ $(id -u) == 0 ]] || die "run as root (sudo)"
[[ -f $PACKAGE ]] || die "no package $PACKAGE (pi/deploy/package.sh makes one)"
for tool in curl sha256sum xz losetup parted e2fsck resize2fs ansible-playbook jq tar; do
  command -v "$tool" >/dev/null || die "missing $tool"
done
if [[ $(uname -m) != aarch64 ]] && ! grep -qs '^flags:.*F' /proc/sys/fs/binfmt_misc/qemu-aarch64; then
  die "not an ARM host and no qemu-aarch64 binfmt (with the F flag): install qemu-user-binfmt"
fi

manifest=$(tar -xzOf "$PACKAGE" --wildcards '*/manifest.json')
VERSION=$(jq -er .version <<<"$manifest")
BOARD=$(jq -er .firmware_chip <<<"$manifest")
NAME=hexapod-$VERSION-$BOARD
log "building $NAME from $(basename "$BASE_URL")"

# --- 1. base image (cached, checked) ------------------------------------
mkdir -p "$CACHE"
base=$CACHE/$(basename "$BASE_URL")
if [[ ! -f $base ]] || ! echo "$BASE_SHA256  $base" | sha256sum -c --status; then
  log "downloading the base image"
  curl -fL --retry 3 -o "$base.part" "$BASE_URL"
  mv "$base.part" "$base"
fi
echo "$BASE_SHA256  $base" | sha256sum -c --status || die "base image checksum mismatch"

WORK=$(mktemp -d /var/tmp/hexapod-image.XXXX)
MNT=$WORK/root
LOOP=""
cleanup() {
  set +e
  for m in boot/firmware dev/pts dev proc sys run; do
    mountpoint -q "$MNT/$m" && umount -l "$MNT/$m"
  done
  mountpoint -q "$MNT" && umount -l "$MNT"
  [[ -n $LOOP ]] && losetup -d "$LOOP"
  rm -rf "$WORK"
}
trap cleanup EXIT

img=$WORK/$NAME.img
log "unpacking"
xz -dc "$base" >"$img"
truncate -s +"${GROW_GB}G" "$img"
parted -s "$img" resizepart 2 100%

LOOP=$(losetup -fP --show "$img")
e2fsck -fy "${LOOP}p2" >/dev/null || true
resize2fs "${LOOP}p2" >/dev/null

mkdir -p "$MNT"
mount "${LOOP}p2" "$MNT"
mount "${LOOP}p1" "$MNT/boot/firmware"
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount -t proc proc "$MNT/proc"
mount -t sysfs sys "$MNT/sys"
mount -t tmpfs tmpfs "$MNT/run"

# Network for apt inside, and no service may start while packages install.
resolv_backup=$WORK/resolv.conf
cp -a "$MNT/etc/resolv.conf" "$resolv_backup" 2>/dev/null || true
rm -f "$MNT/etc/resolv.conf"
cp /etc/resolv.conf "$MNT/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' >"$MNT/usr/sbin/policy-rc.d"
chmod +x "$MNT/usr/sbin/policy-rc.d"

# --- 2. the same playbook as a maker's Pi ---------------------------------
log "provisioning (Ansible, image mode)"
printf 'all:\n  children:\n    hexapod:\n      hosts:\n        image:\n          ansible_host: %s\n          ansible_connection: community.general.chroot\n' "$MNT" \
  >"$WORK/inventory.yml"
(cd "$PI/provision" && ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook site.yml \
  -i "$WORK/inventory.yml" -e ansible_become=false \
  -e image_build=true -e apt_upgrade=false -e provision_reboot=false)

# --- 3. the release, as deploy.sh would install it -------------------------
log "installing release $VERSION"
root=$MNT/opt/hexapod
release=$root/releases/$VERSION
mkdir -p "$release"
tar -xzf "$PACKAGE" -C "$release" --strip-components=1
(cd "$release" && jq -r '"\(.firmware_sha256)  firmware/firmware.bin\n\(.hexd_sha256)  bin/hexd"' manifest.json |
  sha256sum -c --quiet) || die "package checksum mismatch"
ln -sfn "releases/$VERSION" "$root/current"
mkdir -p "$root/shared/firmware"
touch "$root/shared/firmware/flash-on-first-boot" # hexapod-firmware-sync flashes the ESP32
chroot "$MNT" chown -R hexapod:hexapod /opt/hexapod

# --- 4. nothing personal, nothing repeated between robots ------------------
log "cleaning"
rm -f "$MNT/usr/sbin/policy-rc.d" "$MNT/etc/resolv.conf"
cp -a "$resolv_backup" "$MNT/etc/resolv.conf" 2>/dev/null || true
rm -f "$MNT"/etc/ssh/ssh_host_* # each robot makes its own on first boot
chroot "$MNT" systemctl enable regenerate_ssh_host_keys.service >/dev/null 2>&1 || true
: >"$MNT/etc/machine-id"
rm -f "$MNT/var/lib/dbus/machine-id"
chroot "$MNT" apt-get clean
rm -rf "$MNT/root/.ansible" "$MNT/tmp/"* "$MNT/var/tmp/"*

for m in boot/firmware dev/pts dev proc sys run; do umount "$MNT/$m"; done
umount "$MNT"
e2fsck -fy "${LOOP}p2" >/dev/null || true
losetup -d "$LOOP"
LOOP=""

# --- 5. compressed image + checksum ----------------------------------------
mkdir -p "$OUT"
log "compressing"
xz -T0 -6 -c "$img" >"$OUT/$NAME.img.xz"
(cd "$OUT" && sha256sum "$NAME.img.xz" >"$NAME.img.xz.sha256")
log "done: $OUT/$NAME.img.xz ($(du -h "$OUT/$NAME.img.xz" | cut -f1))"
