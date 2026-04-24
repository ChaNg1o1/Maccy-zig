#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
zig build -Doptimize=ReleaseFast
APP="dist/Maccy.app"
ICONSET="dist/AppIcon.iconset"
ICON_PNG="assets/logo.png"
MENUBAR_SVG="assets/menubar.svg"
MENUBAR_PNG="$APP/Contents/Resources/MenubarTemplate.png"
rm -rf "$APP"
rm -rf "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp resources/Info.plist "$APP/Contents/Info.plist"
cp zig-out/bin/maccy-zig "$APP/Contents/MacOS/maccy-zig"
cp assets/logo.png "$APP/Contents/Resources/logo.png"
cp assets/logo-thumb.png "$APP/Contents/Resources/logo-thumb.png"
cp assets/logo-mark.png "$APP/Contents/Resources/logo-mark.png"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
chmod +x "$APP/Contents/MacOS/maccy-zig"
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
magick -background none -density 288 "$MENUBAR_SVG" -resize 36x36 "PNG32:$MENUBAR_PNG"
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'\"' '/Apple Development:/ { print $2; exit }')"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="-"
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" >/dev/null
printf '%s\n' "$APP"
