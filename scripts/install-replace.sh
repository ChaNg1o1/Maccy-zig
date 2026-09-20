#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALLED="/Applications/MaccyZig.app"

# Designated requirement of whatever is installed right now. TCC keyed the
# existing Accessibility grant to this string; if the new bundle's requirement
# differs, that grant is dead weight -- System Settings keeps showing a ticked
# MaccyZig while AXIsProcessTrusted() says no, and every paste re-prompts. We
# reset the entry so the user re-grants once instead of forever.
old_requirement=""
if [ -d "$INSTALLED" ]; then
  old_requirement="$(codesign -d -r- "$INSTALLED" 2>/dev/null | sed -n 's/^# designated => //p' || true)"
fi

APP="$(./scripts/package-app.sh | tail -1)"
new_requirement="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^# designated => //p' || true)"

# Upstream Maccy is optional; when it is not installed the importer just fails
# to open a database that does not exist. Don't print a raw Zig error for that.
if ! ./zig-out/bin/maccy-zig import-maccy --max-blob-mib "${MAX_BLOB_MIB:-4}" 2>/dev/null; then
  printf 'no upstream Maccy history to import; skipping\n'
fi

# MaccyZig installs alongside upstream Maccy — it must never delete or replace
# /Applications/Maccy.app. Earlier revisions of this script did exactly that;
# if you were bitten, look for backups under ~/Backups/MaccyZig-*.
if pgrep -x MaccyZig >/dev/null 2>&1 || pgrep -x maccy-zig >/dev/null 2>&1; then
  osascript -e 'tell application "MaccyZig" to quit' >/dev/null 2>&1 || true
  pkill -x maccy-zig >/dev/null 2>&1 || true
  sleep 2
fi

rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"

if [ -n "$old_requirement" ] && [ "$old_requirement" != "$new_requirement" ]; then
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED/Contents/Info.plist")"
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  printf 'signing identity changed; reset the Accessibility grant for %s\n' "$BUNDLE_ID"
  printf 'grant it once more in Privacy & Security -> Accessibility; it will stick from now on\n'
fi

open -a "$INSTALLED"
printf 'installed %s\n' "$INSTALLED"
