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
  # magick menubar icon - optional

SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'\"' '/Developer ID Application:|Apple Development:/ { print $2; exit }')"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="-"
fi
# Hardened runtime + timestamp keep the signature notarization-ready when a
# real Developer ID identity is available; harmless for ad-hoc.
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" >/dev/null
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP" >/dev/null
fi
printf '%s\n' "$APP"
