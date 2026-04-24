#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

ARTIFACT_DIR="${ARTIFACT_DIR:-dist/verification}"
mkdir -p "$ARTIFACT_DIR"

APP="${APP:-$(./scripts/package-app.sh)}"
BIN="$APP/Contents/MacOS/maccy-zig"
PLIST="$APP/Contents/Info.plist"
HELP_OUT="$ARTIFACT_DIR/bundle-help.txt"
CODESIGN_OUT="$ARTIFACT_DIR/codesign-verify.txt"
MANIFEST_OUT="$ARTIFACT_DIR/package-smoke.txt"

[ -d "$APP" ]
[ -f "$PLIST" ]
[ -x "$BIN" ]

plutil -lint "$PLIST" >"$ARTIFACT_DIR/info-plist-lint.txt"
codesign --verify --deep --strict "$APP" >"$CODESIGN_OUT" 2>&1
"$BIN" --help >"$HELP_OUT" 2>&1

{
  printf 'app=%s\n' "$APP"
  printf 'bin=%s\n' "$BIN"
  printf 'plist=%s\n' "$PLIST"
  printf 'help_output=%s\n' "$HELP_OUT"
  printf 'codesign_output=%s\n' "$CODESIGN_OUT"
  shasum -a 256 "$BIN"
} >"$MANIFEST_OUT"

printf 'package smoke ok\nartifact=%s\n' "$MANIFEST_OUT"
