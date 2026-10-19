#!/usr/bin/env bash
# Development video source on the PC, same as the robot: MediaMTX serving the
# `cam` path over WebRTC/WHEP, fed by an ffmpeg test pattern (and `mic` with a
# test tone). Lets the app be developed without the camera.
#
#   pi/mediamtx/dev-video.sh            # Ctrl+C stops everything
#
# App settings: host = this PC's IP (or 127.0.0.1 on the Linux build).
# Browser check: http://127.0.0.1:8889/cam
set -euo pipefail

VERSION=$(sed -n 's/^mediamtx_version: *//p' "$(dirname "$0")/../provision/group_vars/all.yml")
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/hexapod/mediamtx-$VERSION"
BIN="$CACHE/mediamtx"

if [[ ! -x $BIN ]]; then
  mkdir -p "$CACHE"
  base="https://github.com/bluenviron/mediamtx/releases/download/$VERSION"
  file="mediamtx_${VERSION}_linux_amd64.tar.gz"
  echo "== downloading MediaMTX $VERSION"
  curl -fsSL "$base/$file" -o "$CACHE/$file"
  (cd "$CACHE" && curl -fsSL "$base/checksums.sha256" | grep -E " \*?$file\$" | sha256sum -c --quiet)
  tar -xzf "$CACHE/$file" -C "$CACHE" mediamtx
fi

CONF=$(mktemp --suffix=.yml)
cat >"$CONF" <<'EOF'
logLevel: warn
rtsp: yes
rtspAddress: :8554
rtspTransports: [tcp]
webrtc: yes
webrtcAddress: :8889
hls: no
rtmp: no
srt: no
api: yes
apiAddress: 127.0.0.1:9997
paths:
  cam:
    source: publisher
  mic:
    source: publisher
EOF

pids=()
cleanup() { kill "${pids[@]}" 2>/dev/null || true; rm -f "$CONF"; }
trap cleanup EXIT INT TERM

"$BIN" "$CONF" &
pids+=($!)
sleep 1

# H.264 constrained baseline, no B-frames: what the robot's hardware encoder
# produces and what every WebRTC stack decodes.
ffmpeg -hide_banner -loglevel error -re \
  -f lavfi -i "testsrc2=size=1280x720:rate=30" \
  -vf "drawtext=text='hexapod dev %{localtime\\:%T}':x=40:y=40:fontsize=36:fontcolor=white:box=1:boxcolor=black@0.5" \
  -c:v libx264 -preset ultrafast -tune zerolatency -profile:v baseline -pix_fmt yuv420p -bf 0 -g 30 \
  -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/cam &
pids+=($!)

ffmpeg -hide_banner -loglevel error -re \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" \
  -c:a libopus -b:a 32k -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/mic &
pids+=($!)

echo "== video: http://127.0.0.1:8889/cam (WHEP: /cam/whep). Ctrl+C to stop."
wait
