#!/usr/bin/env bash
# Builds a release package: dist/hexapod-<version>.tar.gz
#
#   pi/deploy/package.sh                 # firmware for the bench board (esp32dev)
#   BOARD=esp32s3 pi/deploy/package.sh   # firmware for the robot board
#
# Contents:
#   manifest.json            version, git hash, firmware chip and version
#   bin/hexd                 linux/arm64
#   firmware/firmware.bin    merged image, flashed at 0x0
#   deploy.sh                the deploy script of this same version
#
# The version is `git describe --tags --always` and is baked into hexd and the
# firmware, so deploy.sh can check what is actually running after the update.
set -euo pipefail

REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
BOARD=${BOARD:-esp32dev}
VERSION=$(git -C "$REPO" describe --tags --always --dirty)
GIT_HASH=$(git -C "$REPO" rev-parse HEAD)
if [[ $VERSION == *-dirty && ${ALLOW_DIRTY:-0} != 1 ]]; then
  echo "package: uncommitted changes ($VERSION); commit first or ALLOW_DIRTY=1" >&2
  exit 1
fi
case $BOARD in
  esp32dev) CHIP=esp32 ;;
  esp32s3) CHIP=esp32s3 ;;
  *) echo "package: unknown BOARD=$BOARD" >&2; exit 1 ;;
esac
export PATH="$PATH:$HOME/go/bin:$HOME/.local/bin"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/hexapod-$VERSION"
mkdir -p "$PKG/bin" "$PKG/firmware" "$REPO/dist"

echo "== firmware ($BOARD)"
(cd "$REPO/firmware" && pio run -e "$BOARD" -t merged >/dev/null)
cp "$REPO/firmware/.pio/build/$BOARD/firmware-merged.bin" "$PKG/firmware/firmware.bin"

echo "== hexd (linux/arm64)"
# The Go protocol code is generated, not committed: make it here, so the
# package builds on a fresh checkout (CI image and deploy workflows).
(cd "$REPO/proto" && buf generate --template buf.gen.pi.yaml)
(cd "$REPO/pi" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath \
  -ldflags "-s -w -X main.version=$VERSION -X main.gitHash=$GIT_HASH" \
  -o "$PKG/bin/hexd" ./hexd/cmd/hexd)

cp "$REPO/pi/deploy/deploy.sh" "$PKG/deploy.sh"
cat > "$PKG/manifest.json" <<EOF
{
  "version": "$VERSION",
  "git_hash": "$GIT_HASH",
  "firmware_version": "$VERSION",
  "firmware_chip": "$CHIP",
  "firmware_board": "$BOARD",
  "firmware_sha256": "$(sha256sum "$PKG/firmware/firmware.bin" | cut -d' ' -f1)",
  "hexd_sha256": "$(sha256sum "$PKG/bin/hexd" | cut -d' ' -f1)"
}
EOF

OUT="$REPO/dist/hexapod-$VERSION.tar.gz"
tar -C "$STAGE" -czf "$OUT" "hexapod-$VERSION"
echo "== $OUT ($(du -h "$OUT" | cut -f1))"
