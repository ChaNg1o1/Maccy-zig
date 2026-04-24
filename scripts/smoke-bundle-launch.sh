#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

ARTIFACT_DIR="${ARTIFACT_DIR:-dist/verification}"
mkdir -p "$ARTIFACT_DIR"

APP="${APP:-${1:-dist/Maccy.app}}"
if [ ! -d "$APP" ]; then
  APP="$(./scripts/package-app.sh)"
fi

BIN="$APP/Contents/MacOS/maccy-zig"
WAIT_SECS="${WAIT_SECS:-3}"
LOG_OUT="$ARTIFACT_DIR/bundle-launch.log"
STATUS_OUT="$ARTIFACT_DIR/bundle-launch.txt"

[ -x "$BIN" ]

"$BIN" >"$LOG_OUT" 2>&1 &
PID=$!
cleanup() {
  if kill -0 "$PID" >/dev/null 2>&1; then
    kill "$PID" >/dev/null 2>&1 || true
    wait "$PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

sleep "$WAIT_SECS"

if ! kill -0 "$PID" >/dev/null 2>&1; then
  wait "$PID"
  printf 'bundle launch failed: process exited before %ss\nlog=%s\n' "$WAIT_SECS" "$LOG_OUT" >&2
  exit 1
fi

{
  printf 'app=%s\n' "$APP"
  printf 'bin=%s\n' "$BIN"
  printf 'pid=%s\n' "$PID"
  printf 'wait_secs=%s\n' "$WAIT_SECS"
  printf 'log=%s\n' "$LOG_OUT"
} >"$STATUS_OUT"

printf 'bundle launch smoke ok\nartifact=%s\n' "$STATUS_OUT"
