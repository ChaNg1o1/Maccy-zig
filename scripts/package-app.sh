#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Universal build: native arch + the other one via Zig cross-compilation.
# Set UNIVERSAL=0 to package a single-arch (native) binary for local testing.
UNIVERSAL="${UNIVERSAL:-1}"
# Version stamp for Info.plist, e.g. VERSION=0.2.0 (from the release tag).
VERSION="${VERSION:-}"

zig build -Doptimize=ReleaseFast
BIN="zig-out/bin/maccy-zig"

if [ "$UNIVERSAL" = "1" ]; then
  SDK_PATH="$(xcrun --show-sdk-path)"
  NATIVE_ARCH="$(uname -m)"
  if [ "$NATIVE_ARCH" = "arm64" ]; then
    OTHER_TARGET="x86_64-macos"
  else
    OTHER_TARGET="aarch64-macos"
  fi
  zig build -Dtarget="$OTHER_TARGET" -Doptimize=ReleaseFast \
    --sysroot "$SDK_PATH" --prefix zig-out/cross
  mkdir -p dist
  lipo -create zig-out/bin/maccy-zig zig-out/cross/bin/maccy-zig \
    -output dist/maccy-zig-universal
  BIN="dist/maccy-zig-universal"
fi

# MaccyZig.app, NOT Maccy.app: the original name collided with (and the old
# install instructions overwrote) the upstream Maccy users may already have.
APP="dist/MaccyZig.app"
ICONSET="dist/AppIcon.iconset"
ICON_PNG="assets/logo.png"
MENUBAR_SVG="assets/menubar.svg"
MENUBAR_PNG="$APP/Contents/Resources/MenubarTemplate.png"
rm -rf "$APP"
rm -rf "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/maccy-zig"
cp assets/logo.png "$APP/Contents/Resources/logo.png"
cp assets/logo-thumb.png "$APP/Contents/Resources/logo-thumb.png"
cp assets/logo-mark.png "$APP/Contents/Resources/logo-mark.png"
chmod +x "$APP/Contents/MacOS/maccy-zig"

if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  # CFBundleVersion must be a monotonically comparable build number.
  BUILD_NUMBER="$(printf '%s' "$VERSION" | awk -F. '{ printf "%d%02d%02d", $1, $2, $3 }')"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

mkdir -p "$ICONSET"
for size in 16 32 64 128 256 512; do
  sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
done
sips -z 32 32 "$ICON_PNG" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 64 64 "$ICON_PNG" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
sips -s format png -z 36 36 "$MENUBAR_SVG" --out "$MENUBAR_PNG" >/dev/null

# --- Code signing -----------------------------------------------------------
# TCC (Accessibility) remembers a grant by the app's *designated requirement*.
# An ad-hoc signature has no certificate, so its designated requirement is a
# bare `cdhash H"..."` that changes on every single rebuild. The old grant row
# keeps showing a ticked "MaccyZig" in System Settings while AXIsProcessTrusted()
# returns false for the new binary -- that is the "looks granted, still prompts
# on every paste" bug. Signing with a certificate makes the requirement
# `identifier "..." and ... certificate leaf[subject.CN] = "..."`, which is
# stable across rebuilds, so the grant survives reinstalls.
#
# The identity is pinned, never guessed: picking "the first identity the
# keychain happens to list" silently changes the designated requirement when the
# keychain order changes, which breaks the grant again. Precedence:
#   1. $CODESIGN_IDENTITY
#   2. the .signing-identity file at the repo root (gitignored)
# Ad-hoc is still reachable, but only by asking for it: CODESIGN_IDENTITY=-
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && [ -f .signing-identity ]; then
  SIGN_IDENTITY="$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' .signing-identity | head -1)"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  {
    echo "error: no signing identity pinned."
    echo "Write one of these into .signing-identity (or export CODESIGN_IDENTITY):"
    security find-identity -v -p codesigning || true
    echo
    echo "Use CODESIGN_IDENTITY=- only for throwaway builds: an ad-hoc signature"
    echo "invalidates the Accessibility grant on every rebuild."
  } >&2
  exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "warning: ad-hoc signing; the Accessibility grant will not survive this rebuild." >&2
  codesign --force --identifier "$BUNDLE_ID" --sign - "$APP" >/dev/null
else
  # Hardened runtime + timestamp keep the signature notarization-ready when a
  # real Developer ID identity is available.
  codesign --force --options runtime --timestamp \
    --identifier "$BUNDLE_ID" --sign "$SIGN_IDENTITY" "$APP" >/dev/null
fi
codesign --verify --strict "$APP"

printf '%s\n' "$APP"
