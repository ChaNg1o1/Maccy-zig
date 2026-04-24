#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
zig build -Doptimize=ReleaseFast
DB="${1:-/tmp/maccy-zig-profile.sqlite}"
rm -f "$DB" "$DB-shm" "$DB-wal"
/usr/bin/time -l ./zig-out/bin/maccy-zig once --db "$DB" --max-blob-mib "${MAX_BLOB_MIB:-4}" --no-images
./zig-out/bin/maccy-zig stats --db "$DB"
