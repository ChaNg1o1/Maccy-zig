#!/usr/bin/env python3
"""Run MaccyZig's repeated macOS performance experiment and Pareto analysis."""

from __future__ import annotations

import argparse
import itertools
import json
import math
import platform
import random
import re
import shutil
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence


@dataclass(frozen=True)
class Candidate:
    candidate_id: str
    optimize: str
    max_items: int
    poll_interval_ms: int
    max_blob_mib: int
    images: bool


def command_output(args: Sequence[str], default: str = "unknown") -> str:
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        return default


def load_space(path: Path) -> tuple[dict[str, Any], list[Candidate]]:
    space = json.loads(path.read_text(encoding="utf-8"))
    raw_candidates = space.get("candidates")
    if raw_candidates is None:
        grid = space.get("grid")
        if not isinstance(grid, dict) or not grid:
            raise ValueError("space must contain non-empty 'candidates' or 'grid'")
        keys = list(grid)
        raw_candidates = [
            dict(zip(keys, values))
            for values in itertools.product(*(grid[key] for key in keys))
        ]

    required = ("optimize", "max_items", "poll_interval_ms", "max_blob_mib", "images")
    candidates: list[Candidate] = []
    seen: set[str] = set()
    for index, raw in enumerate(raw_candidates, 1):
        missing = [key for key in required if key not in raw]
        if missing:
            raise ValueError(f"candidate {index} missing fields: {missing}")
        candidate_id = raw.get("id") or raw.get("candidate_id")
        if not candidate_id:
            candidate_id = "-".join(
                [
                    str(raw["optimize"]).lower(),
                    f"n{int(raw['max_items'])}",
                    f"p{int(raw['poll_interval_ms'])}",
                    f"b{int(raw['max_blob_mib'])}",
                    "img" if bool(raw["images"]) else "text",
                ]
            )
        candidate_id = str(candidate_id)
        if not re.fullmatch(r"[A-Za-z0-9._-]+", candidate_id):
            raise ValueError(f"unsafe candidate id: {candidate_id!r}")
        if candidate_id in seen:
            raise ValueError(f"duplicate candidate id: {candidate_id}")
        seen.add(candidate_id)
        candidates.append(
            Candidate(
                candidate_id=candidate_id,
                optimize=str(raw["optimize"]),
                max_items=int(raw["max_items"]),
                poll_interval_ms=int(raw["poll_interval_ms"]),
                max_blob_mib=int(raw["max_blob_mib"]),
                images=bool(raw["images"]),
            )
        )
    return space, candidates


def print_candidates(candidates: Sequence[Candidate]) -> None:
    print("candidate_id\toptimize\tmax_items\tpoll_interval_ms\tmax_blob_mib\timages")
    for candidate in candidates:
        print(
            f"{candidate.candidate_id}\t{candidate.optimize}\t{candidate.max_items}\t"
            f"{candidate.poll_interval_ms}\t{candidate.max_blob_mib}\t"
            f"{'true' if candidate.images else 'false'}"
        )


def require_match(text: str, pattern: str, label: str, cast: type = float) -> Any:
    match = re.search(pattern, text)
    if not match:
        excerpt = "\n".join(text.splitlines()[-80:])
        raise RuntimeError(f"could not parse {label}; benchmark log tail:\n{excerpt}")
    return cast(match.group(1))


def parse_bench_log(text: str) -> dict[str, Any]:
    insert: dict[int, int] = {}
    pattern = r"size=\s*(\d+)\s+insert_us=\s*([+-]?\d+)"
    for size, latency in re.findall(pattern, text):
        insert[int(size)] = int(latency)
    for required_size in (64, 1024, 65536, 1048576):
        if required_size not in insert:
            excerpt = "\n".join(text.splitlines()[-80:])
            raise RuntimeError(
                f"missing insert metric for {required_size} bytes; benchmark log tail:\n{excerpt}"
            )

    return {
        "insert_64b_us": insert[64],
        "insert_1k_us": insert[1024],
        "insert_64k_us": insert[65536],
        "insert_1m_us": insert[1048576],
        "seed_per_row_us": require_match(
            text,
            r"phase2_total_ms=[+-]?\d+\s+per_row_us=([+-]?\d+)",
            "seed per-row",
            int,
        ),
        "refresh_us": require_match(text, r"phase3_refresh_us=([+-]?\d+)", "refresh", int),
        "prune_us": require_match(text, r"phase4_prune_us=([+-]?\d+)", "prune", int),
        "pruned_rows": require_match(
            text,
            r"phase4_prune_us=[+-]?\d+\s+removed=([+-]?\d+)",
            "pruned rows",
            int,
        ),
        "bench_peak_rss_bytes": require_match(
            text,
            r"([+-]?\d+)\s+maximum resident set size",
            "maximum RSS",
            int,
        ),
        "wall_ms": 1000.0
        * require_match(text, r"([+-]?[0-9.]+)\s+real", "wall time", float),
    }


SEARCH_SQL = r"""
SELECT id, title, COALESCE(app, ''), copy_count, last_copied_at
FROM history_items
WHERE (?1 = '' OR title LIKE '%' || ?1 || '%' ESCAPE '\'
       OR app LIKE '%' || ?1 || '%' ESCAPE '\')
  AND (pin IS NOT NULL OR id IN (
        SELECT id FROM history_items WHERE pin IS NULL
        ORDER BY last_copied_at DESC, id DESC LIMIT ?2))
ORDER BY last_copied_at DESC, id DESC;
"""


def percentile(values: Sequence[float], probability: float) -> float:
    ordered = sorted(values)
    position = probability * (len(ordered) - 1)
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] * (1.0 - fraction) + ordered[upper] * fraction


def sample_search(connection: sqlite3.Connection, term: str, max_items: int, repetitions: int) -> tuple[float, float]:
    for _ in range(20):
        list(connection.execute(SEARCH_SQL, (term, max_items)))
    timings: list[float] = []
    for _ in range(repetitions):
        started = time.perf_counter_ns()
        list(connection.execute(SEARCH_SQL, (term, max_items)))
        timings.append((time.perf_counter_ns() - started) / 1000.0)
    return statistics.median(timings), percentile(timings, 0.95)


def measure_search(db_path: Path, max_items: int, repetitions: int) -> dict[str, float]:
    connection = sqlite3.connect(db_path)
    try:
        connection.execute("PRAGMA query_only=ON")
        hit_median, hit_p95 = sample_search(connection, "stress-row", max_items, repetitions)
        miss_median, miss_p95 = sample_search(
            connection, "no-such-token-6f9cc5", max_items, repetitions
        )
    finally:
        connection.close()
    return {
        "search_hit_median_us": hit_median,
        "search_hit_p95_us": hit_p95,
        "search_miss_median_us": miss_median,
        "search_miss_p95_us": miss_p95,
        "search_p95_us": max(hit_p95, miss_p95),
    }


def machine_metadata(repo_root: Path) -> dict[str, Any]:
    return {
        "arch": platform.machine(),
        "os_version": command_output(["sw_vers", "-productVersion"]),
        "os_build": command_output(["sw_vers", "-buildVersion"]),
        "machine_model": command_output(["sysctl", "-n", "hw.model"]),
        "cpu_brand": command_output(["sysctl", "-n", "machdep.cpu.brand_string"]),
        "logical_cpu": command_output(["sysctl", "-n", "hw.logicalcpu"]),
        "physical_memory_bytes": command_output(["sysctl", "-n", "hw.memsize"]),
        "zig_version": command_output(["zig", "version"]),
        "git_commit": command_output(["git", "-C", str(repo_root), "rev-parse", "HEAD"]),
    }


def run_checked(args: Sequence[str], cwd: Path | None = None) -> None:
    subprocess.run(list(args), cwd=cwd, check=True)


def build_binaries(repo_root: Path, build_root: Path, candidates: Sequence[Candidate]) -> dict[str, Path]:
    binaries: dict[str, Path] = {}
    for optimize in sorted({candidate.optimize for candidate in candidates}):
        print(f"building optimize={optimize}", file=sys.stderr, flush=True)
        run_checked(["zig", "build", f"-Doptimize={optimize}"], cwd=repo_root)
        destination = build_root / optimize / "maccy-zig"
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(repo_root / "zig-out/bin/maccy-zig", destination)
        destination.chmod(0o755)
        binaries[optimize] = destination
    return binaries


def remove_db(path: Path) -> None:
    for candidate in (path, Path(f"{path}-wal"), Path(f"{path}-shm")):
        candidate.unlink(missing_ok=True)


def run_bench(binary: Path, candidate: Candidate, db_path: Path, seed_count: int) -> str:
    remove_db(db_path)
    command = [
        "/usr/bin/time",
        "-l",
        str(binary),
        "bench",
        "--db",
        str(db_path),
        "--count",
        str(seed_count),
        "--max-items",
        str(candidate.max_items),
        "--max-blob-mib",
        str(candidate.max_blob_mib),
        "--interval-ms",
        str(candidate.poll_interval_ms),
    ]
    if not candidate.images:
        command.append("--no-images")
    completed = subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"benchmark failed for {candidate.candidate_id} with exit {completed.returncode}:\n"
            f"{completed.stdout}"
        )
    return completed.stdout


def db_footprint(path: Path) -> int:
    return sum(
        candidate.stat().st_size
        for candidate in (path, Path(f"{path}-wal"), Path(f"{path}-shm"))
        if candidate.exists()
    )


def analyze_results(repo_root: Path, space: dict[str, Any], output: Path, report_dir: Path) -> None:
    analysis = space.get("analysis", {})
    command = [
        sys.executable,
        str(repo_root / "scripts/pareto.py"),
        "--input",
        str(output),
        "--output-dir",
        str(report_dir),
        "--stat",
        str(analysis.get("stat", "p95")),
        "--epsilon",
        str(analysis.get("epsilon", 0.03)),
    ]
    objectives = analysis.get("objectives", [])
    if objectives:
        command.extend(["--objectives", ",".join(map(str, objectives))])
    maximize = analysis.get("maximize", [])
    if maximize:
        command.extend(["--maximize", ",".join(map(str, maximize))])
    for constraint in analysis.get("constraints", []):
        command.extend(["--require", str(constraint)])
    for key, value in analysis.get("weights", {}).items():
        command.extend(["--weight", f"{key}={value}"])
    for key, value in analysis.get("epsilon_metric", {}).items():
        command.extend(["--epsilon-metric", f"{key}={value}"])
    run_checked(command, cwd=repo_root)


def run_experiment(args: argparse.Namespace, repo_root: Path, space: dict[str, Any], candidates: list[Candidate]) -> int:
    if platform.system() != "Darwin":
        raise RuntimeError("benchmark-pareto must run on macOS")
    if shutil.which("zig") is None:
        raise RuntimeError("zig is required")
    if not Path("/usr/bin/time").exists():
        raise RuntimeError("/usr/bin/time is required")

    runs = args.runs if args.runs is not None else int(space.get("runs", 7))
    warmups = args.warmups if args.warmups is not None else int(space.get("warmups", 2))
    seed_count = args.seed_count if args.seed_count is not None else int(space.get("seed_count", 5000))
    search_repetitions = int(space.get("search_repetitions", 200))
    if runs <= 0 or warmups < 0 or seed_count <= 0 or search_repetitions <= 0:
        raise ValueError("runs/seed/search repetitions must be positive; warmups non-negative")

    output = args.output or repo_root / "benchmarks/results" / f"{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}.jsonl"
    report_dir = args.report_dir or repo_root / "benchmarks/reports" / output.stem
    output = Path(output)
    report_dir = Path(report_dir)
    output.parent.mkdir(parents=True, exist_ok=True)
    report_dir.mkdir(parents=True, exist_ok=True)
    output.write_text("", encoding="utf-8")

    temp_path = Path(tempfile.mkdtemp(prefix="maccy-pareto."))
    try:
        binaries = build_binaries(repo_root, temp_path / "builds", candidates)
        metadata = machine_metadata(repo_root)
        rng = random.Random(args.shuffle_seed)

        warmup_trials = [
            (candidate, run_number)
            for candidate in candidates
            for run_number in range(1, warmups + 1)
        ]
        random.Random(args.shuffle_seed - 1).shuffle(warmup_trials)
        for candidate, run_number in warmup_trials:
            print(
                f"warmup candidate={candidate.candidate_id} run={run_number}/{warmups}",
                file=sys.stderr,
                flush=True,
            )
            run_bench(
                binaries[candidate.optimize],
                candidate,
                temp_path / "db" / f"{candidate.candidate_id}-warmup-{run_number}.sqlite",
                seed_count,
            )

        measured_trials = [
            (candidate, run_number)
            for candidate in candidates
            for run_number in range(1, runs + 1)
        ]
        rng.shuffle(measured_trials)
        for index, (candidate, run_number) in enumerate(measured_trials, 1):
            print(
                f"measure [{index}/{len(measured_trials)}] candidate={candidate.candidate_id} "
                f"run={run_number}/{runs}",
                file=sys.stderr,
                flush=True,
            )
            db_path = temp_path / "db" / f"{candidate.candidate_id}-measure-{run_number}.sqlite"
            db_path.parent.mkdir(parents=True, exist_ok=True)
            text = run_bench(binaries[candidate.optimize], candidate, db_path, seed_count)
            metrics = parse_bench_log(text)
            metrics.update(measure_search(db_path, candidate.max_items, search_repetitions))
            row = {
                "candidate_id": candidate.candidate_id,
                "run": run_number,
                "optimize": candidate.optimize,
                "max_items": candidate.max_items,
                "poll_interval_ms": candidate.poll_interval_ms,
                "max_blob_mib": candidate.max_blob_mib,
                "images": candidate.images,
                "seed_count": seed_count,
                **metrics,
                "binary_bytes": binaries[candidate.optimize].stat().st_size,
                "db_bytes": db_footprint(db_path),
                **metadata,
            }
            with output.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")

        print(f"measurements: {output}", file=sys.stderr)
        if not args.no_analyze:
            analyze_results(repo_root, space, output, report_dir)
        return 0
    finally:
        if args.keep_temp:
            print(f"temporary files preserved at {temp_path}", file=sys.stderr)
        else:
            shutil.rmtree(temp_path, ignore_errors=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--space", type=Path, default=None)
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--report-dir", type=Path, default=None)
    parser.add_argument("--runs", type=int, default=None)
    parser.add_argument("--warmups", type=int, default=None)
    parser.add_argument("--seed-count", type=int, default=None)
    parser.add_argument("--shuffle-seed", type=int, default=20260815)
    parser.add_argument("--no-analyze", action="store_true")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--keep-temp", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    return parser


def self_test() -> int:
    sample = """
      size=      64 insert_us=     +1950
      size=    1024 insert_us=       +96
      size=   65536 insert_us=      +186
      size= 1048576 insert_us=     +5648
    phase2_total_ms=1 per_row_us=+80 seeded=3
    phase3_refresh_us=+52 rows=2
    phase4_prune_us=+179 removed=+5
            12345678  maximum resident set size
            0.25 real 0.10 user 0.05 sys
    """
    parsed = parse_bench_log(sample)
    assert parsed["insert_64b_us"] == 1950
    assert parsed["insert_1m_us"] == 5648
    assert parsed["bench_peak_rss_bytes"] == 12345678
    assert parsed["wall_ms"] == 250.0
    print("benchmark_runner.py self-test passed")
    return 0


def main() -> int:
    args = build_parser().parse_args()
    if args.self_test:
        return self_test()
    repo_root = Path(__file__).resolve().parents[1]
    space_path = args.space or repo_root / "benchmarks/pareto-space.json"
    try:
        space, candidates = load_space(space_path)
        if args.list:
            print_candidates(candidates)
            return 0
        return run_experiment(args, repo_root, space, candidates)
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
