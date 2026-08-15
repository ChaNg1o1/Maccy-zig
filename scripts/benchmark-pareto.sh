#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPACE="$ROOT/benchmarks/pareto-space.json"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="$ROOT/benchmarks/results/$STAMP.jsonl"
REPORT_DIR="$ROOT/benchmarks/reports/$STAMP"
RUNS_OVERRIDE=""
WARMUPS_OVERRIDE=""
SEED_OVERRIDE=""
SHUFFLE_SEED=20260815
ANALYZE=1
LIST_ONLY=0
KEEP_TEMP=0

usage() {
  cat <<'EOF'
Usage: scripts/benchmark-pareto.sh [options]

Options:
  --space PATH          Candidate-space JSON (default: benchmarks/pareto-space.json)
  --output PATH         JSONL output path
  --report-dir PATH     Pareto report directory
  --runs N              Override measured repetitions per candidate
  --warmups N           Override warmups per candidate
  --seed-count N        Override synthetic rows seeded by each run
  --shuffle-seed N      Deterministic measured-trial randomization seed
  --no-analyze          Collect measurements without running pareto.py
  --list                Expand and print candidates; do not build or benchmark
  --keep-temp           Preserve temporary logs and copied binaries
  -h, --help            Show this help

The benchmark must run on macOS because the target links AppKit/Cocoa and uses
BSD /usr/bin/time -l. Results from different machines or OS versions should not
be pooled into one Pareto analysis.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --space) SPACE="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --report-dir) REPORT_DIR="$2"; shift 2 ;;
    --runs) RUNS_OVERRIDE="$2"; shift 2 ;;
    --warmups) WARMUPS_OVERRIDE="$2"; shift 2 ;;
    --seed-count) SEED_OVERRIDE="$2"; shift 2 ;;
    --shuffle-seed) SHUFFLE_SEED="$2"; shift 2 ;;
    --no-analyze) ANALYZE=0; shift ;;
    --list) LIST_ONLY=1; shift ;;
    --keep-temp) KEEP_TEMP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
[ -f "$SPACE" ] || { echo "candidate space not found: $SPACE" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/maccy-pareto.XXXXXX")"
cleanup() {
  if [ "$KEEP_TEMP" -eq 1 ]; then
    echo "temporary files preserved at $TMP" >&2
  else
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT INT TERM

CANDIDATES="$TMP/candidates.tsv"
CONFIG_ENV="$TMP/config.env"

python3 - "$SPACE" "$CANDIDATES" "$CONFIG_ENV" <<'PY'
import itertools
import json
import re
import shlex
import sys
from pathlib import Path

space_path, candidates_path, env_path = map(Path, sys.argv[1:])
space = json.loads(space_path.read_text(encoding="utf-8"))

candidates = space.get("candidates")
if candidates is None:
    grid = space.get("grid")
    if not isinstance(grid, dict) or not grid:
        raise SystemExit("space must contain non-empty 'candidates' or 'grid'")
    keys = list(grid)
    candidates = [dict(zip(keys, values)) for values in itertools.product(*(grid[key] for key in keys))]

required = ("optimize", "max_items", "poll_interval_ms", "max_blob_mib", "images")
seen = set()
rows = []
for index, raw in enumerate(candidates, 1):
    candidate = dict(raw)
    missing = [key for key in required if key not in candidate]
    if missing:
        raise SystemExit(f"candidate {index} missing fields: {missing}")
    candidate_id = candidate.get("id") or candidate.get("candidate_id")
    if not candidate_id:
        candidate_id = "-".join(
            [
                str(candidate["optimize"]).lower(),
                f"n{candidate['max_items']}",
                f"p{candidate['poll_interval_ms']}",
                f"b{candidate['max_blob_mib']}",
                "img" if candidate["images"] else "text",
            ]
        )
    if not re.fullmatch(r"[A-Za-z0-9._-]+", str(candidate_id)):
        raise SystemExit(f"unsafe candidate id: {candidate_id!r}")
    if candidate_id in seen:
        raise SystemExit(f"duplicate candidate id: {candidate_id}")
    seen.add(candidate_id)
    rows.append(
        (
            candidate_id,
            str(candidate["optimize"]),
            int(candidate["max_items"]),
            int(candidate["poll_interval_ms"]),
            int(candidate["max_blob_mib"]),
            "true" if bool(candidate["images"]) else "false",
        )
    )

with candidates_path.open("w", encoding="utf-8") as handle:
    for row in rows:
        handle.write("\t".join(map(str, row)) + "\n")

analysis = space.get("analysis", {})
values = {
    "RUNS": int(space.get("runs", 7)),
    "WARMUPS": int(space.get("warmups", 2)),
    "SEED_COUNT": int(space.get("seed_count", 5000)),
    "SEARCH_REPETITIONS": int(space.get("search_repetitions", 200)),
    "ANALYSIS_STAT": str(analysis.get("stat", "p95")),
    "ANALYSIS_EPSILON": float(analysis.get("epsilon", 0.03)),
    "ANALYSIS_OBJECTIVES": ",".join(analysis.get("objectives", [])),
    "ANALYSIS_CONSTRAINTS": "\x1f".join(analysis.get("constraints", [])),
    "ANALYSIS_WEIGHTS": "\x1f".join(f"{key}={value}" for key, value in analysis.get("weights", {}).items()),
    "ANALYSIS_EPSILON_METRIC": "\x1f".join(f"{key}={value}" for key, value in analysis.get("epsilon_metric", {}).items()),
}
with env_path.open("w", encoding="utf-8") as handle:
    for key, value in values.items():
        handle.write(f"{key}={shlex.quote(str(value))}\n")
PY

# shellcheck disable=SC1090
. "$CONFIG_ENV"
RUNS="${RUNS_OVERRIDE:-$RUNS}"
WARMUPS="${WARMUPS_OVERRIDE:-$WARMUPS}"
SEED_COUNT="${SEED_OVERRIDE:-$SEED_COUNT}"

case "$RUNS:$WARMUPS:$SEED_COUNT" in
  *[!0-9:]*|:*|*::*|*:) echo "runs, warmups, and seed-count must be non-negative integers" >&2; exit 2 ;;
esac
[ "$RUNS" -gt 0 ] || { echo "runs must be > 0" >&2; exit 2; }
[ "$SEED_COUNT" -gt 0 ] || { echo "seed-count must be > 0" >&2; exit 2; }

if [ "$LIST_ONLY" -eq 1 ]; then
  printf 'candidate_id\toptimize\tmax_items\tpoll_interval_ms\tmax_blob_mib\timages\n'
  cat "$CANDIDATES"
  exit 0
fi

[ "$(uname -s)" = "Darwin" ] || { echo "benchmark-pareto.sh must run on macOS" >&2; exit 1; }
command -v zig >/dev/null 2>&1 || { echo "zig is required" >&2; exit 1; }
[ -x /usr/bin/time ] || { echo "/usr/bin/time is required" >&2; exit 1; }

mkdir -p "$(dirname "$OUTPUT")" "$REPORT_DIR" "$TMP/builds" "$TMP/logs" "$TMP/db"
: > "$OUTPUT"

MACHINE_JSON="$TMP/machine.json"
python3 - "$MACHINE_JSON" "$ROOT" <<'PY'
import json
import platform
import subprocess
import sys
from pathlib import Path


def command(*args):
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return "unknown"

repo_root = sys.argv[2]
payload = {
    "arch": platform.machine(),
    "os_version": command("sw_vers", "-productVersion"),
    "os_build": command("sw_vers", "-buildVersion"),
    "machine_model": command("sysctl", "-n", "hw.model"),
    "cpu_brand": command("sysctl", "-n", "machdep.cpu.brand_string"),
    "logical_cpu": command("sysctl", "-n", "hw.logicalcpu"),
    "physical_memory_bytes": command("sysctl", "-n", "hw.memsize"),
    "zig_version": command("zig", "version"),
    "git_commit": command("git", "-C", repo_root, "rev-parse", "HEAD"),
}
Path(sys.argv[1]).write_text(json.dumps(payload), encoding="utf-8")
PY

cd "$ROOT"

# Build every optimization mode once, then preserve the exact executable used
# by all randomized trials. This removes rebuild variance from runtime metrics.
cut -f2 "$CANDIDATES" | sort -u | while IFS= read -r optimize; do
  echo "building optimize=$optimize" >&2
  zig build -Doptimize="$optimize"
  mkdir -p "$TMP/builds/$optimize"
  cp "$ROOT/zig-out/bin/maccy-zig" "$TMP/builds/$optimize/maccy-zig"
  chmod +x "$TMP/builds/$optimize/maccy-zig"
done

run_trial() {
  candidate_id="$1"
  optimize="$2"
  max_items="$3"
  poll_interval_ms="$4"
  max_blob_mib="$5"
  images="$6"
  trial_kind="$7"
  run_number="$8"

  binary="$TMP/builds/$optimize/maccy-zig"
  db="$TMP/db/${candidate_id}-${trial_kind}-${run_number}.sqlite"
  log="$TMP/logs/${candidate_id}-${trial_kind}-${run_number}.log"
  rm -f "$db" "$db-shm" "$db-wal"

  set -- "$binary" bench \
    --db "$db" \
    --count "$SEED_COUNT" \
    --max-items "$max_items" \
    --max-blob-mib "$max_blob_mib" \
    --interval-ms "$poll_interval_ms"
  if [ "$images" = "false" ]; then
    set -- "$@" --no-images
  fi

  if ! /usr/bin/time -l "$@" >"$log" 2>&1; then
    echo "benchmark failed: candidate=$candidate_id kind=$trial_kind run=$run_number" >&2
    tail -n 80 "$log" >&2 || true
    exit 1
  fi

  if [ "$trial_kind" = "warmup" ]; then
    return 0
  fi

  python3 - \
    "$log" "$db" "$binary" "$OUTPUT" "$MACHINE_JSON" \
    "$candidate_id" "$run_number" "$optimize" "$max_items" \
    "$poll_interval_ms" "$max_blob_mib" "$images" "$SEED_COUNT" \
    "$SEARCH_REPETITIONS" <<'PY'
import json
import math
import os
import re
import sqlite3
import statistics
import sys
import time
from pathlib import Path

(
    log_path,
    db_path,
    binary_path,
    output_path,
    machine_path,
    candidate_id,
    run_number,
    optimize,
    max_items,
    poll_interval_ms,
    max_blob_mib,
    images,
    seed_count,
    search_repetitions,
) = sys.argv[1:]

text = Path(log_path).read_text(encoding="utf-8", errors="replace")


def require(pattern, label, cast=float):
    match = re.search(pattern, text)
    if not match:
        raise SystemExit(f"could not parse {label} from {log_path}")
    return cast(match.group(1))

insert = {}
for size, latency in re.findall(r"size=\s*(\d+)\s+insert_us=\s*(\d+)", text):
    insert[int(size)] = int(latency)
for required_size in (64, 1024, 65536, 1048576):
    if required_size not in insert:
        raise SystemExit(f"missing insert metric for {required_size} bytes in {log_path}")

seed_per_row_us = require(r"phase2_total_ms=\d+\s+per_row_us=(\d+)", "seed per-row", int)
refresh_us = require(r"phase3_refresh_us=(\d+)", "refresh", int)
prune_us = require(r"phase4_prune_us=(\d+)", "prune", int)
removed = require(r"phase4_prune_us=\d+\s+removed=(\d+)", "pruned rows", int)
peak_rss_bytes = require(r"(\d+)\s+maximum resident set size", "maximum RSS", int)
wall_seconds = require(r"([0-9.]+)\s+real", "wall time", float)

query = r"""
SELECT id, title, COALESCE(app, ''), copy_count, last_copied_at
FROM history_items
WHERE (?1 = '' OR title LIKE '%' || ?1 || '%' ESCAPE '\'
       OR app LIKE '%' || ?1 || '%' ESCAPE '\')
  AND (pin IS NOT NULL OR id IN (
        SELECT id FROM history_items WHERE pin IS NULL
        ORDER BY last_copied_at DESC, id DESC LIMIT ?2))
ORDER BY last_copied_at DESC, id DESC;
"""

connection = sqlite3.connect(db_path)
connection.execute("PRAGMA query_only=ON")


def sample_search(term, repetitions):
    for _ in range(20):
        list(connection.execute(query, (term, int(max_items))))
    timings = []
    for _ in range(repetitions):
        start = time.perf_counter_ns()
        list(connection.execute(query, (term, int(max_items))))
        timings.append((time.perf_counter_ns() - start) / 1000.0)
    timings.sort()
    index = 0.95 * (len(timings) - 1)
    lo = math.floor(index)
    hi = math.ceil(index)
    p95 = timings[lo] if lo == hi else timings[lo] * (hi - index) + timings[hi] * (index - lo)
    return statistics.median(timings), p95

hit_median, hit_p95 = sample_search("stress-row", int(search_repetitions))
miss_median, miss_p95 = sample_search("no-such-token-6f9cc5", int(search_repetitions))
connection.close()

binary_bytes = os.path.getsize(binary_path)
db_bytes = sum(os.path.getsize(path) for path in (db_path, db_path + "-wal", db_path + "-shm") if os.path.exists(path))
machine = json.loads(Path(machine_path).read_text(encoding="utf-8"))

row = {
    "candidate_id": candidate_id,
    "run": int(run_number),
    "optimize": optimize,
    "max_items": int(max_items),
    "poll_interval_ms": int(poll_interval_ms),
    "max_blob_mib": int(max_blob_mib),
    "images": images == "true",
    "seed_count": int(seed_count),
    "insert_64b_us": insert[64],
    "insert_1k_us": insert[1024],
    "insert_64k_us": insert[65536],
    "insert_1m_us": insert[1048576],
    "seed_per_row_us": seed_per_row_us,
    "refresh_us": refresh_us,
    "prune_us": prune_us,
    "pruned_rows": removed,
    "search_hit_median_us": hit_median,
    "search_hit_p95_us": hit_p95,
    "search_miss_median_us": miss_median,
    "search_miss_p95_us": miss_p95,
    "search_p95_us": max(hit_p95, miss_p95),
    "bench_peak_rss_bytes": peak_rss_bytes,
    "wall_ms": wall_seconds * 1000.0,
    "binary_bytes": binary_bytes,
    "db_bytes": db_bytes,
    **machine,
}
with Path(output_path).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
PY
}

# Warm every candidate before measured trials. Warmups are deliberately not
# shuffled into measured runs: a measured repetition must never precede its
# candidate's cache/toolchain warmup.
if [ "$WARMUPS" -gt 0 ]; then
  python3 - "$CANDIDATES" "$TMP/warmups.tsv" "$WARMUPS" "$SHUFFLE_SEED" <<'PY'
import random
import sys
from pathlib import Path

source, target, count, seed = sys.argv[1:]
rows = [line.rstrip("\n") for line in Path(source).read_text(encoding="utf-8").splitlines() if line.strip()]
trials = []
for line in rows:
    for index in range(1, int(count) + 1):
        trials.append(f"{line}\twarmup\t{index}")
random.Random(int(seed) - 1).shuffle(trials)
Path(target).write_text("\n".join(trials) + "\n", encoding="utf-8")
PY
  while IFS="$(printf '\t')" read -r candidate_id optimize max_items poll_interval_ms max_blob_mib images kind run_number; do
    echo "warmup candidate=$candidate_id run=$run_number/$WARMUPS" >&2
    run_trial "$candidate_id" "$optimize" "$max_items" "$poll_interval_ms" "$max_blob_mib" "$images" "$kind" "$run_number"
  done < "$TMP/warmups.tsv"
fi

# Interleave measured repetitions across candidates to decorrelate candidate
# identity from thermal drift, Spotlight/noisy-neighbour activity, and battery
# state. The seed is recorded by the command invocation for reproducibility.
python3 - "$CANDIDATES" "$TMP/trials.tsv" "$RUNS" "$SHUFFLE_SEED" <<'PY'
import random
import sys
from pathlib import Path

source, target, count, seed = sys.argv[1:]
rows = [line.rstrip("\n") for line in Path(source).read_text(encoding="utf-8").splitlines() if line.strip()]
trials = []
for line in rows:
    for index in range(1, int(count) + 1):
        trials.append(f"{line}\tmeasure\t{index}")
random.Random(int(seed)).shuffle(trials)
Path(target).write_text("\n".join(trials) + "\n", encoding="utf-8")
PY

TOTAL_TRIALS=$((RUNS * $(wc -l < "$CANDIDATES" | tr -d ' ')))
COMPLETED=0
while IFS="$(printf '\t')" read -r candidate_id optimize max_items poll_interval_ms max_blob_mib images kind run_number; do
  COMPLETED=$((COMPLETED + 1))
  echo "measure [$COMPLETED/$TOTAL_TRIALS] candidate=$candidate_id run=$run_number/$RUNS" >&2
  run_trial "$candidate_id" "$optimize" "$max_items" "$poll_interval_ms" "$max_blob_mib" "$images" "$kind" "$run_number"
done < "$TMP/trials.tsv"

echo "measurements: $OUTPUT" >&2

if [ "$ANALYZE" -eq 1 ]; then
  set -- python3 "$ROOT/scripts/pareto.py" \
    --input "$OUTPUT" \
    --output-dir "$REPORT_DIR" \
    --stat "$ANALYSIS_STAT" \
    --epsilon "$ANALYSIS_EPSILON"
  if [ -n "$ANALYSIS_OBJECTIVES" ]; then
    set -- "$@" --objectives "$ANALYSIS_OBJECTIVES"
  fi
  old_ifs="$IFS"
  IFS="$(printf '\037')"
  for constraint in $ANALYSIS_CONSTRAINTS; do
    [ -n "$constraint" ] && set -- "$@" --require "$constraint"
  done
  for weight in $ANALYSIS_WEIGHTS; do
    [ -n "$weight" ] && set -- "$@" --weight "$weight"
  done
  for metric_epsilon in $ANALYSIS_EPSILON_METRIC; do
    [ -n "$metric_epsilon" ] && set -- "$@" --epsilon-metric "$metric_epsilon"
  done
  IFS="$old_ifs"
  "$@"
fi
