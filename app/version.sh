#!/usr/bin/env bash
# Prints the `flutter build` flags that stamp the app with the repository
# version, the same `git describe` the robot uses (hexd and firmware):
#   --build-name    last tag without the "v" (Android versionName, e.g. 0.7.0)
#   --build-number  commit count (versionCode: always grows, as Play requires)
#   APP_VERSION     the full describe shown in Settings (e.g. v0.7.0-3-gabc1234)
set -euo pipefail
describe=$(git describe --tags --always --dirty)
tag=$(git describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)
echo "--build-name=${tag#v} --build-number=$(git rev-list --count HEAD) --dart-define=APP_VERSION=$describe"
