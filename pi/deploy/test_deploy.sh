#!/usr/bin/env bash
# End-to-end test of deploy.sh on the PC, no root and no hardware:
# real hexd + hexsim, fake systemctl (starts/stops hexd) and fake esptool
# ("flashing" restarts hexsim reporting the new firmware version).
#
#   pi/deploy/test_deploy.sh
set -euo pipefail

PI=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
ROOT="$WORK/opt"
BIN="$WORK/bin"
STATE="$WORK/state"
mkdir -p "$ROOT/shared/config" "$BIN" "$STATE"
export PATH="$PATH:$HOME/go/bin"
SIM_PORT=17777 HTTP_PORT=18080

cleanup() {
  for pidfile in "$STATE"/*.pid; do
    [[ -f $pidfile ]] && kill "$(cat "$pidfile")" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

pass=0
ok() { printf '  \e[32mPASS\e[0m %s\n' "$*"; pass=$((pass + 1)); }
fail() {
  printf '  \e[31mFAIL\e[0m %s\n' "$*"
  echo "--- deploy.log (tail)"; tail -25 "$STATE/deploy.log" 2>/dev/null
  echo "--- hexd.log (tail)"; tail -8 "$STATE/hexd.log" 2>/dev/null | cut -c1-160
  exit 1
}

echo "== building"
(cd "$PI" && go build -o "$BIN/hexsim" ./hexsim && go build -o "$BIN/hexctl" ./cmd/hexctl)

cat >"$ROOT/shared/config/hexd.yaml" <<EOF
listen: 127.0.0.1:$HTTP_PORT
serial:
  device: tcp://127.0.0.1:$SIM_PORT
  silence_limit: 1s
shutdown:
  enabled: false
EOF

start_sim() { # firmware_version
  [[ -f $STATE/sim.pid ]] && kill "$(cat "$STATE/sim.pid")" 2>/dev/null && sleep 0.2
  "$BIN/hexsim" -listen "tcp://127.0.0.1:$SIM_PORT" -firmware "$1" -boot-noise >>"$STATE/sim.log" 2>&1 &
  echo $! >"$STATE/sim.pid"
  echo "$1" >"$STATE/firmware"
  sleep 0.3
}

# Fake systemctl: only `stop|start|restart hexd`.
cat >"$BIN/systemctl" <<EOF
#!/usr/bin/env bash
set -e
stop() { [[ -f $STATE/hexd.pid ]] && kill \$(cat $STATE/hexd.pid) 2>/dev/null || true; rm -f $STATE/hexd.pid; sleep 0.2; }
start() { $ROOT/current/bin/hexd -config $ROOT/shared/config/hexd.yaml >>$STATE/hexd.log 2>&1 & echo \$! > $STATE/hexd.pid; }
case "\$1" in stop) stop ;; start) start ;; restart) stop; start ;; *) exit 1 ;; esac
EOF
# Fake esptool: write-flash restarts the simulator with the image's version.
cat >"$BIN/esptool" <<EOF
#!/usr/bin/env bash
set -e
echo "esptool \$*" >> $STATE/esptool.log
args=("\$@")
for i in "\${!args[@]}"; do
  case "\${args[\$i]}" in
    write-flash) img="\${args[\$((i+2))]}"; v=\$(sed 's/^fw://' "\$img")
                 [[ -f $STATE/sim.pid ]] && kill \$(cat $STATE/sim.pid) 2>/dev/null; sleep 0.2
                 $BIN/hexsim -listen tcp://127.0.0.1:$SIM_PORT -firmware "\$v" >>$STATE/sim.log 2>&1 &
                 echo \$! > $STATE/sim.pid; echo "\$v" > $STATE/firmware; sleep 0.3; exit 0 ;;
    read-flash)  echo "fw:\$(cat $STATE/firmware)" > "\${args[\$((i+3))]}"; exit 0 ;;
  esac
done
exit 1
EOF
chmod +x "$BIN/systemctl" "$BIN/esptool"

mkpkg() { # version good|broken -> path of the .tar.gz
  local v=$1 kind=$2 dir="$WORK/pkg/hexapod-$1"
  mkdir -p "$dir/bin" "$dir/firmware"
  if [[ $kind == good ]]; then
    (cd "$PI" && go build -ldflags "-X main.version=$v" -o "$dir/bin/hexd" ./hexd/cmd/hexd)
  else
    printf '#!/bin/sh\nexit 1\n' >"$dir/bin/hexd" && chmod +x "$dir/bin/hexd"
  fi
  echo "fw:$v" >"$dir/firmware/firmware.bin"
  cp "$PI/deploy/deploy.sh" "$dir/"
  cat >"$dir/manifest.json" <<EOF
{"version":"$v","git_hash":"x","firmware_version":"$v","firmware_chip":"esp32","firmware_board":"esp32dev",
 "firmware_sha256":"$(sha256sum "$dir/firmware/firmware.bin" | cut -d' ' -f1)",
 "hexd_sha256":"$(sha256sum "$dir/bin/hexd" | cut -d' ' -f1)"}
EOF
  tar -C "$WORK/pkg" -czf "$WORK/pkg/hexapod-$v.tar.gz" "hexapod-$v"
  echo "$WORK/pkg/hexapod-$v.tar.gz"
}

deploy() {
  HEXAPOD_ROOT=$ROOT HEXD_URL=http://127.0.0.1:$HTTP_PORT ESP32_PORT=/dev/null \
    ESPTOOL=$BIN/esptool SYSTEMCTL=$BIN/systemctl SERVICE_USER=$(id -un) VERIFY_SECONDS=8 \
    bash "$PI/deploy/deploy.sh" "$@" >>"$STATE/deploy.log" 2>&1
}
status_state() { curl -fsS "http://127.0.0.1:$HTTP_PORT/status" | jq -r .state; }
version_of() { curl -fsS "http://127.0.0.1:$HTTP_PORT/version" | jq -r ".$1"; }
current() { basename "$(readlink -f "$ROOT/current")"; }
wait_state() { # state...
  for _ in $(seq 60); do
    s=$(status_state 2>/dev/null || true)
    for want in "$@"; do [[ $s == "$want" ]] && return 0; done
    sleep 0.1
  done
  return 1
}

start_sim "fw-factory"

echo "== 1. first install"
P1=$(mkpkg v1 good)
deploy "$P1" && fail "deployed without hexd and without --bootstrap"
grep -q "hexd not answering" "$STATE/deploy.log" || fail "refused for another reason"
[[ ! -e $ROOT/current ]] && ok "refused without --bootstrap"
deploy "$P1" --bootstrap || fail "bootstrap deploy"
[[ $(current) == v1 && $(version_of hexd_version) == v1 && $(version_of firmware_version) == v1 ]] &&
  ok "bootstrap: hexd v1, firmware v1" || fail "bootstrap result"

echo "== 2. robot standing"
P2=$(mkpkg v2 good)
"$BIN/hexctl" -url "ws://127.0.0.1:$HTTP_PORT/ws" -for 3s stand >/dev/null &
wait_state NORMAL || fail "robot did not stand"
deploy "$P2" && fail "deployed while standing"
grep -q "robot is NORMAL: sit it down first" "$STATE/deploy.log" || fail "refused for another reason"
[[ $(current) == v1 ]] && ok "refused while NORMAL, still v1"
wait
wait_state SAFE_SIT RELAXED || fail "robot did not sit after the app went silent"

echo "== 3. update with new firmware"
deploy "$P2" || fail "deploy v2"
[[ $(current) == v2 && $(version_of firmware_version) == v2 ]] && ok "hexd and firmware v2" || fail "v2 result"
[[ $(cat "$ROOT/shared/firmware/v1.bin") == fw:v1 ]] && ok "previous firmware v1 kept" || fail "no v1 backup"

echo "== 4. broken release rolls back"
P3=$(mkpkg v3 broken)
deploy "$P3" && fail "broken release reported success"
[[ $(current) == v2 ]] && ok "current back to v2" || fail "current is $(current)"
wait_state RELAXED SAFE_SIT || true
[[ $(version_of hexd_version) == v2 && $(version_of firmware_version) == v2 ]] &&
  ok "hexd v2 answering, firmware re-flashed to v2" || fail "rollback state"
grep -q "write-flash 0x0 $ROOT/shared/firmware/v2.bin" "$STATE/esptool.log" && ok "rollback flashed the v2 image" ||
  fail "rollback did not flash v2"

echo "== 5. keeps the last 5 releases"
for v in v4 v5 v6 v7 v8; do
  wait_state RELAXED SAFE_SIT || fail "not seated before $v"
  deploy "$(mkpkg $v good)" || fail "deploy $v"
done
n=$(ls -1d "$ROOT"/releases/*/ | wc -l)
[[ $(current) == v8 && $n -le 5 ]] && ok "current v8, $n releases kept" || fail "current $(current), $n releases"

echo "== 6. tampered package"
P9=$(mkpkg v9 good)
mkdir -p "$WORK/t" && tar -C "$WORK/t" -xzf "$P9" && echo junk >>"$WORK/t/hexapod-v9/bin/hexd" &&
  tar -C "$WORK/t" -czf "$P9" hexapod-v9
deploy "$P9" && fail "tampered package deployed"
grep -q "package checksum mismatch" "$STATE/deploy.log" || fail "refused for another reason"
[[ $(current) == v8 ]] && ok "checksum mismatch refused" || fail "tampered result"

echo "== $pass checks passed"
