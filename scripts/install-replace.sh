#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$(./scripts/package-app.sh)"
./zig-out/bin/maccy-zig import-maccy --max-blob-mib "${MAX_BLOB_MIB:-4}" || true
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/Backups/MaccyZig-$TS}"
mkdir -p "$BACKUP_ROOT"
if pgrep -x Maccy >/dev/null 2>&1 || pgrep -x MaccyZig >/dev/null 2>&1 || pgrep -x maccy-zig >/dev/null 2>&1; then
  # Try both display names: pre-v0.0.5 builds called themselves "Maccy",
  # v0.0.5+ uses "MaccyZig". Either AppleScript silently no-ops if the name
  # is unknown, so running both is safe.
  osascript -e 'tell application "MaccyZig" to quit' >/dev/null 2>&1 || true
  osascript -e 'tell application "Maccy" to quit' >/dev/null 2>&1 || true
  pkill -x maccy-zig >/dev/null 2>&1 || true
  sleep 2
fi
if [ -d /Applications/Maccy.app ]; then
  ditto /Applications/Maccy.app "$BACKUP_ROOT/Maccy.app"
fi
ORIG_CONTAINER="$HOME/Library/Containers/org.p0deje.Maccy"
ORIG_DB_DIR="$ORIG_CONTAINER/Data/Library/Application Support/Maccy"
ORIG_PREF_DIR="$ORIG_CONTAINER/Data/Library/Preferences"
mkdir -p "$BACKUP_ROOT/OriginalData/Maccy" "$BACKUP_ROOT/OriginalData/Preferences"
for f in "$ORIG_DB_DIR"/Storage.sqlite "$ORIG_DB_DIR"/Storage.sqlite-wal "$ORIG_DB_DIR"/Storage.sqlite-shm; do
  [ -f "$f" ] && cp -p "$f" "$BACKUP_ROOT/OriginalData/Maccy/" || true
done
for f in "$ORIG_PREF_DIR"/org.p0deje.Maccy.plist; do
  [ -f "$f" ] && cp -p "$f" "$BACKUP_ROOT/OriginalData/Preferences/" || true
done
cat > "$BACKUP_ROOT/restore.sh" <<RESTORE
#!/usr/bin/env bash
set -euo pipefail
if [ -d "$BACKUP_ROOT/Maccy.app" ]; then
  rm -rf /Applications/Maccy.app
  ditto "$BACKUP_ROOT/Maccy.app" /Applications/Maccy.app
fi
echo "Original DB/config backups are under: $BACKUP_ROOT/OriginalData"
open -a Maccy
RESTORE
chmod +x "$BACKUP_ROOT/restore.sh"
rm -rf /Applications/Maccy.app
ditto "$APP" /Applications/Maccy.app
open -a /Applications/Maccy.app
printf 'installed /Applications/Maccy.app\nbackup=%s\nrestore=%s\n' "$BACKUP_ROOT" "$BACKUP_ROOT/restore.sh"
