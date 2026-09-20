#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

ARTIFACT_DIR="${ARTIFACT_DIR:-dist/verification}"
mkdir -p "$ARTIFACT_DIR"

APP="${APP:-$(./scripts/package-app.sh | tail -1)}"
BIN="$APP/Contents/MacOS/maccy-zig"
PLIST="$APP/Contents/Info.plist"
HELP_OUT="$ARTIFACT_DIR/bundle-help.txt"
CODESIGN_OUT="$ARTIFACT_DIR/codesign-verify.txt"
LIPO_OUT="$ARTIFACT_DIR/lipo-archs.txt"
MANIFEST_OUT="$ARTIFACT_DIR/package-smoke.txt"

[ -d "$APP" ]
[ -f "$PLIST" ]
[ -x "$BIN" ]

plutil -lint "$PLIST" >"$ARTIFACT_DIR/info-plist-lint.txt"
codesign --verify --deep --strict "$APP" >"$CODESIGN_OUT" 2>&1
lipo -archs "$BIN" >"$LIPO_OUT" 2>&1 || true
"$BIN" --help >"$HELP_OUT" 2>&1

# Every slice has to run on the macOS version Info.plist promises. A native Zig
# build is otherwise stamped with the version of the machine it was built on:
# v0.0.5 shipped as `minos 15.7.4` under an Info.plist that said 14.0.
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
for arch in $(lipo -archs "$BIN"); do
  built_for="$(vtool -arch "$arch" -show-build "$BIN" | awk '$1 == "minos" { print $2 }')"
  if [ "$built_for" != "$MIN_MACOS" ]; then
    echo "error: $arch slice is built for macOS $built_for, Info.plist says $MIN_MACOS" >&2
    exit 1
  fi
done

{
  printf 'app=%s\n' "$APP"
  printf 'bin=%s\n' "$BIN"
  printf 'plist=%s\n' "$PLIST"
  printf 'archs=%s\n' "$(cat "$LIPO_OUT")"
  printf 'help_output=%s\n' "$HELP_OUT"
  printf 'codesign_output=%s\n' "$CODESIGN_OUT"
  shasum -a 256 "$BIN"
} >"$MANIFEST_OUT"

printf 'package smoke ok\nartifact=%s\n' "$MANIFEST_OUT"
