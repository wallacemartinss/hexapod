#!/usr/bin/env bash
# Splits the Pi's SD card into a small root and a writable data partition for
# /opt/hexapod, so the root can later be made read-only (hexapod-readonly on).
# Runs on the PC, with the card in a reader and NOT mounted:
#
#   sudo pi/provision/make-data-partition.sh /dev/sdX
#
# What it does (nothing is deleted):
#   1. fsck the root (partition 2, label rootfs);
#   2. shrink it to ROOT_GB (default 24; the system uses ~4 GB);
#   3. create partition 3, ext4 label "hexdata", with the rest of the card;
#   4. copy /opt/hexapod there (owners kept), keep the old copy on the root as
#      /opt/hexapod.before-data, and add the mount to the root's /etc/fstab.
# Make a backup image of the card first (see the runbook).
set -euo pipefail

ROOT_GB=${ROOT_GB:-24}
LABEL=hexdata
dev=${1:-}

die() { echo "error: $*" >&2; exit 1; }
[[ $(id -u) == 0 ]] || die "run with sudo"
[[ -b $dev ]] || die "usage: sudo $0 /dev/sdX (the SD card, not a partition)"
for tool in parted e2fsck resize2fs mkfs.ext4 rsync blkid lsblk partprobe; do
  command -v "$tool" >/dev/null || die "missing $tool"
done

# Partition device names: /dev/sdb1, but /dev/mmcblk0p1 and /dev/loop0p1.
part() { if [[ $dev =~ [0-9]$ ]]; then echo "${dev}p$1"; else echo "${dev}$1"; fi; }
p1=$(part 1) p2=$(part 2) p3=$(part 3)

# --- safety checks: this must be a hexapod Pi card, untouched -------------
[[ $(lsblk -dno TYPE "$dev") == disk || $dev == /dev/loop* ]] || die "$dev is not a whole disk"
if [[ $dev != /dev/loop* && $(lsblk -dno RM "$dev") != 1 && ${ALLOW_FIXED:-} != 1 ]]; then
  die "$dev is not removable (an internal disk?). Set ALLOW_FIXED=1 only if you are sure."
fi
[[ $(blkid -s LABEL -o value "$p1" 2>/dev/null) == bootfs ]] || die "$p1 is not the Pi boot partition (label bootfs)"
[[ $(blkid -s LABEL -o value "$p2" 2>/dev/null) == rootfs ]] || die "$p2 is not the Pi root (label rootfs)"
[[ $(blkid -s TYPE -o value "$p2") == ext4 ]] || die "$p2 is not ext4"
[[ ! -b $p3 ]] || die "$p3 already exists: the card was already split"
if lsblk -no MOUNTPOINT "$dev" | grep -q .; then
  die "partitions of $dev are mounted; unmount them first (umount ${dev}*)"
fi

sector=$(cat "/sys/class/block/$(basename "$dev")/queue/logical_block_size")
p2_start=$(parted -sm "$dev" unit s print | awk -F: '$1 == 2 {sub("s", "", $2); print $2}')
disk_end=$(parted -sm "$dev" unit s print | awk -F: 'NR == 2 {sub("s", "", $2); print $2 - 1}')
p2_end=$((p2_start + ROOT_GB * 1024 * 1024 * 1024 / sector - 1))
p3_start=$(((p2_end + 1 + 2047) / 2048 * 2048)) # 1 MiB aligned
((p3_start < disk_end - 2048 * 1024)) || die "card too small for a ${ROOT_GB} GB root plus data"

echo "Card $dev ($(lsblk -dno SIZE "$dev")):"
lsblk -o NAME,SIZE,FSTYPE,LABEL "$dev"
echo
echo "Plan: root ($p2) shrinks to ${ROOT_GB} GB; new $p3 ext4 '$LABEL' with the rest for /opt/hexapod."
read -r -p "Type SIM to change the card: " answer
[[ $answer == SIM ]] || die "cancelled, nothing changed"

work=$(mktemp -d)
cleanup() {
  mountpoint -q "$work/root" && umount "$work/root"
  mountpoint -q "$work/data" && umount "$work/data"
  rm -rf "$work"
}
trap cleanup EXIT

echo "== 1/4 fsck and shrink the root"
e2fsck -fy "$p2"
# Shrink the filesystem below the target first, then the partition, then
# grow the filesystem back to fill it exactly: no risk of cutting data.
resize2fs "$p2" "$((ROOT_GB - 2))G"
parted -s "$dev" unit s resizepart 2 "${p2_end}s" 2>/dev/null ||
  echo Yes | parted ---pretend-input-tty "$dev" unit s resizepart 2 "${p2_end}s"
partprobe "$dev"
udevadm settle
resize2fs "$p2"
e2fsck -fy "$p2"

echo "== 2/4 create the data partition"
parted -s "$dev" unit s mkpart primary ext4 "${p3_start}s" 100%
partprobe "$dev"
udevadm settle
mkfs.ext4 -F -L "$LABEL" "$p3"

echo "== 3/4 copy /opt/hexapod"
mkdir -p "$work/root" "$work/data"
mount "$p2" "$work/root"
mount "$p3" "$work/data"
if [[ -d $work/root/opt/hexapod ]]; then
  rsync -aHAX --numeric-ids "$work/root/opt/hexapod/" "$work/data/"
  mv "$work/root/opt/hexapod" "$work/root/opt/hexapod.before-data"
fi
mkdir -p "$work/root/opt/hexapod"
# The data root gets the mount point's owner and mode of the old directory.
if [[ -d $work/root/opt/hexapod.before-data ]]; then
  chown --reference="$work/root/opt/hexapod.before-data" "$work/data"
  chmod --reference="$work/root/opt/hexapod.before-data" "$work/data"
fi

echo "== 4/4 mount it at boot"
fstab=$work/root/etc/fstab
if ! grep -q "LABEL=$LABEL" "$fstab"; then
  printf 'LABEL=%s  /opt/hexapod  ext4  defaults,noatime,commit=30  0  2\n' "$LABEL" >>"$fstab"
fi
sync

echo
echo "Done. Put the card back in the Pi and boot it; then:"
echo "  ansible-playbook site.yml --tags readonly -e readonly_root=true   (from pi/provision)"
lsblk -o NAME,SIZE,FSTYPE,LABEL "$dev"
