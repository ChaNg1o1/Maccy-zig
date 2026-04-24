#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p profile
: > profile/mutation-results.tsv
printf 'optimize\tmax_blob_mib\treal_sec\trss_bytes\tfootprint_bytes\n' >> profile/mutation-results.tsv
for opt in Debug ReleaseSafe ReleaseFast ReleaseSmall; do
  zig build -Doptimize="$opt" >/dev/null
  for mib in 1 4 16; do
    db="/tmp/maccy-zig-mut-${opt}-${mib}.sqlite"
    rm -f "$db" "$db-shm" "$db-wal"
    out=$(/usr/bin/time -l ./zig-out/bin/maccy-zig once --db "$db" --max-blob-mib "$mib" --no-images 2>&1 >/tmp/maccy-zig-mut.out || true)
    real=$(printf '%s\n' "$out" | awk '/ real / {print $1; exit}')
    rss=$(printf '%s\n' "$out" | awk '/maximum resident set size/ {print $1; exit}')
    fp=$(printf '%s\n' "$out" | awk '/peak memory footprint/ {print $1; exit}')
    printf '%s\t%s\t%s\t%s\t%s\n' "$opt" "$mib" "${real:-NA}" "${rss:-NA}" "${fp:-NA}" >> profile/mutation-results.tsv
  done
done
cat profile/mutation-results.tsv
