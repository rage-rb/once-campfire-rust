#!/usr/bin/env bash
# Original 100k workload, with portable local smoke and an external load host for a real Pi.
# Local:    WORK=... [PREPARED=1] run100k.sh BIN LABEL [CLIENTS] [cable options...]
# External: WORK=... BASE=http://pi:4555 PREPARED=1 SOURCES=LAN_IPS run100k.sh - LABEL [CLIENTS]
# Defaults: all available load-host cores; no taskset, CPU quota or Pi emulation.
# APP_CPUS/LOADGEN_CPUS optionally select Linux CPU affinity. See bench/rage/README.md.
set -euo pipefail
[ $# -ge 2 ] || { sed -n '2,6p' "$0" >&2; exit 1; }
BIN=$1; LABEL=$2; shift 2
[[ $LABEL =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'LABEL must contain letters, digits, _ or -' >&2; exit 1; }
N=100000
if [ $# -gt 0 ] && [[ $1 =~ ^[0-9]+$ ]]; then N=$1; shift; fi
REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
WORK=${WORK:-$REPO/bench/.work/pi-100k}
mkdir -p "$WORK/storage"
WORK=$(cd "$WORK" && pwd)
PORT=${PORT:-4555}
LOADGEN=${LOADGEN:-$REPO/target/bench/release/loadgen}
[ -x "$LOADGEN" ] || CARGO_TARGET_DIR=$REPO/target/bench cargo build --release -q --manifest-path "$REPO/bench/loadgen/Cargo.toml"
APP_PID=; LOAD_PID=; SAMPLER=
cleanup() {
  for pid in "$SAMPLER" "$LOAD_PID" "$APP_PID"; do
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -n "${BASE:-}" ]; then
  [ "$BIN" = - ] || { echo 'Use BIN=- with BASE; launch/sample the app on the Pi separately.' >&2; exit 1; }
  [[ $BASE = http://* ]] || { echo 'The benchmark requires plain http://BASE.' >&2; exit 1; }
  SOURCES=${SOURCES:-}
  if [ "$N" -ge 28000 ] && [ -z "$SOURCES" ]; then
    echo 'For 100k remote sockets supply enough assigned LAN SOURCES to avoid ephemeral-port exhaustion.' >&2; exit 1
  fi
  [[ ,$SOURCES, != *,127.* ]] || { echo 'External SOURCES must use addresses assigned to the load host Ethernet interface.' >&2; exit 1; }
else
  BASE=http://127.0.0.1:$PORT
  BIN=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$BIN")
  [ -x "$BIN" ] || { echo "Not executable: $BIN" >&2; exit 1; }
  # Keep separate WORK dirs per implementation. Rage replaces Rails' first-run route with a seed.
  export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(printf 'a%.0s' {1..128})}"
  export CAMPFIRE_STORAGE_PATH=$WORK/storage
  if [ "$BIN" = "$REPO/bench/rage/bin/server" ]; then
    PREPARED=1
    "$REPO/bench/rage/bin/prepare" > "$WORK/prepare.txt"
  fi
  if [ "$(uname -s)" = Linux ]; then
    SOURCES=${SOURCES:-127.0.0.10,127.0.0.11,127.0.0.12,127.0.0.13,127.0.0.14,127.0.0.15,127.0.0.16,127.0.0.17,127.0.0.18,127.0.0.19}
  else
    SOURCES=${SOURCES:-127.0.0.1}
  fi
  curl -sf -o /dev/null "$BASE/up" && { echo "$BASE already serves an app; use a free PORT or external BASE." >&2; exit 1; }
  app_wrap=()
  [ -z "${APP_CPUS:-}" ] || app_wrap=(taskset -c "$APP_CPUS")
  (
    cd "$WORK"
    export DISABLE_SSL=1 HTTP_PORT=$PORT TARGET_PORT=$((PORT + 1))
    exec ${app_wrap[@]+"${app_wrap[@]}"} "$BIN" server
  ) > "$WORK/log" 2>&1 & APP_PID=$!
fi
for ((i=0; i<150; i++)); do
  if curl -sf -o /dev/null "$BASE/up"; then break; fi
  if [ -n "$APP_PID" ] && ! kill -0 "$APP_PID" 2>/dev/null; then echo "App exited; see $WORK/log" >&2; exit 1; fi
  sleep 0.2
done
curl -sf -o /dev/null "$BASE/up" || { echo "App not ready at $BASE" >&2; exit 1; }
if [ ! -f "$WORK/scrape.json" ]; then
  fill_options=()
  [ "${PREPARED:-0}" != 1 ] || fill_options=(--prepared)
  python3 "$REPO/bench/results/splice-20260927/fill.py" "$BASE" ${fill_options[@]+"${fill_options[@]}"} > "$WORK/fill.txt"
  "$LOADGEN" login --base "$BASE" --email david@example.com --password secret123456 |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["cookie"])' > "$WORK/cookie"
  "$LOADGEN" scrape --base "$BASE" --cookie "$(cat "$WORK/cookie")" --room 1 > "$WORK/scrape.json"
fi
COOKIE=$(cat "$WORK/cookie")
STREAMS=$(python3 - "$WORK/scrape.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))["streams"]
assert len(s) == 3 and len(set(s)) == 3, 'Expected exactly three distinct scraped streams'
assert sum(x.startswith('RoomMessagesChannel|') for x in s) == 1
assert sum(x.startswith('Turbo::StreamsChannel|') for x in s) == 2
print(','.join(s))
PY
)
CSRF=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("csrf") or "")' "$WORK/scrape.json")
load_wrap=()
[ -z "${LOADGEN_CPUS:-}" ] || load_wrap=(taskset -c "$LOADGEN_CPUS")
${load_wrap[@]+"${load_wrap[@]}"} "$LOADGEN" cable --base "$BASE" --cookie "$COOKIE" --csrf "$CSRF" --room 1 --streams "$STREAMS" \
  --clients "$N" --sources "$SOURCES" --hold-secs 30 --latency-msgs 10 --tput-secs 10 --posters 2 --wire 1 --deflate 1 "$@" \
  > "$WORK/cable-$LABEL.json" 2> "$WORK/cable-$LABEL.err" & LOAD_PID=$!
python3 "$REPO/bench/sample_process.py" --app-tree "${APP_PID:-0}" --loadgen "$LOAD_PID" > "$WORK/samp-$LABEL.jsonl" & SAMPLER=$!
status=0
wait "$LOAD_PID" || status=$?
LOAD_PID=
kill "$SAMPLER" 2>/dev/null || true
wait "$SAMPLER" 2>/dev/null || true
SAMPLER=
[ "$status" = 0 ] || { echo "Loadgen failed ($status); see $WORK/cable-$LABEL.err" >&2; exit "$status"; }
python3 "$REPO/bench/cable_report.py" "$WORK" "$LABEL"
