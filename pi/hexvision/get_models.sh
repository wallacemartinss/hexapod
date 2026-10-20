#!/usr/bin/env bash
# Person detector for hexvision on a PC: MobileNet-SSD (MIT) at a fixed
# commit, checked by SHA-256. On the robot Ansible does the same
# (pi/provision/tasks/vision.yml).
set -euo pipefail
COMMIT=bb17b6c3eef36d80be441ae8e5339be66e8e3b7a
DIR=${1:-$(dirname "$0")/models}
mkdir -p "$DIR"
while read -r sum file; do
  if ! echo "$sum  $DIR/$file" | sha256sum -c --quiet >/dev/null 2>&1; then
    curl -fsSL -o "$DIR/$file" "https://raw.githubusercontent.com/chuanqi305/MobileNet-SSD/$COMMIT/$file"
    echo "$sum  $DIR/$file" | sha256sum -c --quiet
  fi
done <<SUMS
2d180f723b3109e21f8287f6b3c691390d07b60eed998327cd3259ffa0e50608 deploy.prototxt
52eed8be80522c152a17fb56740de705b79881bde1a167e0e747310523685fc7 mobilenet_iter_73000.caffemodel
SUMS
echo "models in $DIR"
