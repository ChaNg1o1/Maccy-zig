#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$(./scripts/package-app.sh | tail -1)"
./zig-out/bin/maccy-zig import-maccy --max-blob-mib "${MAX_BLOB_MIB:-4}" || true

# MaccyZig installs alongside upstream Maccy — it must never delete or replace
# /Applications/Maccy.app. Earlier revisions of this script did exactly that;
# if you were bitten, look for backups under ~/Backups/MaccyZig-*.
if pgrep -x MaccyZig >/dev/null 2>&1 || pgrep -x maccy-zig >/dev/null 2>&1; then
  osascript -e 'tell application "MaccyZig" to quit' >/dev/null 2>&1 || true
  pkill -x maccy-zig >/dev/null 2>&1 || true
  sleep 2
fi

rm -rf /Applications/MaccyZig.app
ditto "$APP" /Applications/MaccyZig.app
open -a /Applications/MaccyZig.app
printf 'installed /Applications/MaccyZig.app\n'
