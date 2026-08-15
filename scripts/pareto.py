#!/usr/bin/env python3
"""Robust multi-objective analysis for MaccyZig performance experiments.

Input is JSON Lines with one repeated measurement per row. Each row must have
``candidate_id`` plus configuration fields and measured metrics. The analyzer
adds deterministic latency/resource proxies, aggregates repetitions, applies
feasibility constraints, computes epsilon-Pareto fronts, and emits JSON, CSV,
and Markdown reports. It uses only the Python standard library.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import operator
import re
import statistics
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

DEFAULT_OBJECTIVES = (
    "copy_to_ready_ms",
    "search_ms",
    "bench_peak_rss_mib",
    "poll_ticks_per_s",
    "binary_kib",
)

CONFIG_FIELDS = (
    "candidate_id",
    "optimize",
    "max_items",
    "poll_interval_ms",
    "max_blob_mib",
    "images",
    "seed_count",
    "arch",
    "os_version",
    "os_build",
    "machine_model",
    "cpu_brand",
    "logical_cpu",
    "physical_memory_bytes",
    "zig_version",
    "git_commit",
)


class ParetoError(RuntimeError):
    pass


@dataclass(frozen=True)
class Objective:
    name: str
    maximize: bool = False
    epsilon: float = 0.0


@dataclass
class Candidate:
    candidate_id: str
    config: dict[str, Any]
    samples: int
    stats: dict[str, dict[str, float]]
    scores: dict[str, float]
    rank: int = 0
    dominated_by: list[str] | None = None
    compromise_score: float = math.inf
    is_compromise: bool = False

    def as_json(self) -> dict[str, Any]:
        return {
            "candidate_id": self.candidate_id,
            "config": self.config,
            "samples": self.samples,
            "rank": self.rank,
            "dominated_by": self.dominated_by or [],
            "scores": self.scores,
            "stats": self.stats,
            "compromise_score": self.compromise_score,
            "is_compromise": self.is_compromise,
        }


def is_number(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
    )


def quantile(values: Sequence[float], probability: float) -> float:
    if not values:
        raise ParetoError("quantile of empty sample")
    if not 0.0 <= probability <= 1.0:
        raise ParetoError("quantile probability must be in [0, 1]")
    ordered = sorted(float(value) for value in values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * probability
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] * (1.0 - fraction) + ordered[upper] * fraction


def summarize(values: Sequence[float]) -> dict[str, float]:
    numeric = [float(value) for value in values if math.isfinite(float(value))]
    if not numeric:
        raise ParetoError("cannot summarize an empty metric")
    mean = statistics.fmean(numeric)
    median = statistics.median(numeric)
    stdev = statistics.stdev(numeric) if len(numeric) > 1 else 0.0
    mad = statistics.median(abs(value - median) for value in numeric)
    return {
        "count": float(len(numeric)),
        "min": min(numeric),
        "median": median,
        "mean": mean,
        "p95": quantile(numeric, 0.95),
        "max": max(numeric),
        "stdev": stdev,
        "mad": mad,
        "robust_sigma": 1.4826 * mad,
        "ucb95": mean + (1.645 * stdev / math.sqrt(len(numeric)) if len(numeric) > 1 else 0.0),
    }


def derive_metrics(raw: Mapping[str, Any], poll_quantile: float) -> dict[str, Any]:
    row = dict(raw)
    conversions = (
        ("insert_1m_us", "capture_1m_ms", 1.0 / 1000.0),
        ("refresh_us", "refresh_ms", 1.0 / 1000.0),
        ("search_p95_us", "search_ms", 1.0 / 1000.0),
        ("binary_bytes", "binary_kib", 1.0 / 1024.0),
        ("db_bytes", "db_kib", 1.0 / 1024.0),
        ("bench_peak_rss_bytes", "bench_peak_rss_mib", 1.0 / (1024.0 * 1024.0)),
        ("app_idle_rss_kib", "app_idle_rss_mib", 1.0 / 1024.0),
    )
    for source, target, scale in conversions:
        if target not in row and is_number(row.get(source)):
            row[target] = float(row[source]) * scale

    interval = row.get("poll_interval_ms")
    if is_number(interval) and float(interval) > 0:
        interval_ms = float(interval)
        row.setdefault("poll_ticks_per_s", 1000.0 / interval_ms)
        row.setdefault("poll_detection_mean_ms", 0.5 * interval_ms)
        row.setdefault("poll_detection_p95_ms", poll_quantile * interval_ms)
        row.setdefault("poll_detection_p99_ms", 0.99 * interval_ms)

    components = (
        row.get("poll_detection_p95_ms"),
        row.get("capture_1m_ms"),
        row.get("refresh_ms"),
    )
    if "copy_to_ready_ms" not in row and all(is_number(value) for value in components):
        row["copy_to_ready_ms"] = sum(float(value) for value in components)

    if "capture_1m_ops_per_s" not in row and is_number(row.get("capture_1m_ms")):
        latency = float(row["capture_1m_ms"])
        if latency > 0:
            row["capture_1m_ops_per_s"] = 1000.0 / latency
    return row


def load_jsonl(path: Path, poll_quantile: float) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            try:
                value = json.loads(stripped)
            except json.JSONDecodeError as exc:
                raise ParetoError(f"{path}:{line_number}: invalid JSON: {exc}") from exc
            if not isinstance(value, dict):
                raise ParetoError(f"{path}:{line_number}: row must be an object")
            if not value.get("candidate_id"):
                raise ParetoError(f"{path}:{line_number}: missing candidate_id")
            rows.append(derive_metrics(value, poll_quantile))
    if not rows:
        raise ParetoError(f"{path}: no experiment rows")
    return rows


_CONSTRAINT_RE = re.compile(
    r"^\s*([A-Za-z_][A-Za-z0-9_.-]*)\s*(<=|>=|==|!=|<|>)\s*(.*?)\s*$"
)
_OPERATORS: dict[str, Callable[[Any, Any], bool]] = {
    "<": operator.lt,
    "<=": operator.le,
    "==": operator.eq,
    "!=": operator.ne,
    ">=": operator.ge,
    ">": operator.gt,
}


def parse_scalar(text: str) -> Any:
    lowered = text.strip().lower()
    if lowered in {"true", "yes", "on"}:
        return True
    if lowered in {"false", "no", "off"}:
        return False
    if re.fullmatch(r"[-+]?\d+", text.strip()):
        return int(text)
    try:
        return float(text)
    except ValueError:
        return text


def parse_constraint(expression: str) -> tuple[str, str, Any]:
    match = _CONSTRAINT_RE.match(expression)
    if not match:
        raise ParetoError(f"invalid constraint {expression!r}; expected field>=value")
    field, comparison, raw = match.groups()
    return field, comparison, parse_scalar(raw)


def constraint_holds(row: Mapping[str, Any], constraint: tuple[str, str, Any]) -> bool:
    field, comparison, expected = constraint
    if field not in row:
        return False
    actual = row[field]
    try:
        if is_number(actual) and is_number(expected):
            return _OPERATORS[comparison](float(actual), float(expected))
        return _OPERATORS[comparison](actual, expected)
    except TypeError:
        return False


def config_for_group(rows: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    config: dict[str, Any] = {}
    first = rows[0]
    for key in CONFIG_FIELDS:
        if key not in first:
            continue
        values = [row.get(key) for row in rows]
        if all(value == values[0] for value in values):
            config[key] = values[0]
    return config


def aggregate(
    rows: Sequence[Mapping[str, Any]],
    objectives: Sequence[Objective],
    statistic: str,
    constraints: Sequence[tuple[str, str, Any]],
) -> tuple[list[Candidate], int]:
    groups: dict[str, list[Mapping[str, Any]]] = defaultdict(list)
    rejected = 0
    for row in rows:
        if constraints and not all(constraint_holds(row, item) for item in constraints):
            rejected += 1
            continue
        groups[str(row["candidate_id"])].append(row)

    candidates: list[Candidate] = []
    for candidate_id, group in sorted(groups.items()):
        metric_names = sorted(
            {
                key
                for row in group
                for key, value in row.items()
                if is_number(value) and key not in {"run"}
            }
        )
        stats: dict[str, dict[str, float]] = {}
        for metric in metric_names:
            values = [float(row[metric]) for row in group if is_number(row.get(metric))]
            if values:
                stats[metric] = summarize(values)

        scores: dict[str, float] = {}
        missing: list[str] = []
        for objective in objectives:
            if objective.name not in stats:
                missing.append(objective.name)
                continue
            if statistic not in stats[objective.name]:
                raise ParetoError(f"unknown statistic: {statistic}")
            scores[objective.name] = stats[objective.name][statistic]
        if missing:
            raise ParetoError(f"candidate {candidate_id!r} missing objectives: {', '.join(missing)}")

        candidates.append(
            Candidate(
                candidate_id=candidate_id,
                config=config_for_group(group),
                samples=len(group),
                stats=stats,
                scores=scores,
            )
        )
    if not candidates:
        raise ParetoError("all rows were rejected by feasibility constraints")
    return candidates, rejected


def materially_dominates(left: Candidate, right: Candidate, objectives: Sequence[Objective]) -> bool:
    strictly_better = False
    for objective in objectives:
        a = left.scores[objective.name]
        b = right.scores[objective.name]
        tolerance = objective.epsilon * max(abs(a), abs(b), 1e-12)
        if objective.maximize:
            if a < b - tolerance:
                return False
            if a > b + tolerance:
                strictly_better = True
        else:
            if a > b + tolerance:
                return False
            if a < b - tolerance:
                strictly_better = True
    return strictly_better


def rank_fronts(candidates: Sequence[Candidate], objectives: Sequence[Objective]) -> list[list[Candidate]]:
    remaining = list(candidates)
    fronts: list[list[Candidate]] = []
    rank = 1
    while remaining:
        front = [
            candidate
            for candidate in remaining
            if not any(
                materially_dominates(other, candidate, objectives)
                for other in remaining
                if other is not candidate
            )
        ]
        if not front:
            raise ParetoError("dominance ranking produced an empty front")
        for candidate in front:
            candidate.rank = rank
            candidate.dominated_by = sorted(
                other.candidate_id
                for other in candidates
                if other is not candidate and materially_dominates(other, candidate, objectives)
            )
        fronts.append(sorted(front, key=lambda item: item.candidate_id))
        remaining = [candidate for candidate in remaining if candidate not in front]
        rank += 1
    return fronts


def choose_compromise(
    first_front: Sequence[Candidate],
    objectives: Sequence[Objective],
    weights: Mapping[str, float],
) -> Candidate:
    if not first_front:
        raise ParetoError("cannot choose a compromise from an empty front")
    bounds: dict[str, tuple[float, float]] = {}
    for objective in objectives:
        values = [candidate.scores[objective.name] for candidate in first_front]
        bounds[objective.name] = (min(values), max(values))

    best: Candidate | None = None
    for candidate in first_front:
        regrets: list[float] = []
        for objective in objectives:
            low, high = bounds[objective.name]
            span = high - low
            value = candidate.scores[objective.name]
            if span <= 0:
                regret = 0.0
            elif objective.maximize:
                regret = (high - value) / span
            else:
                regret = (value - low) / span
            regrets.append(max(0.0, weights.get(objective.name, 1.0)) * regret)
        candidate.compromise_score = max(regrets, default=0.0) + 0.05 * sum(regrets)
        candidate.is_compromise = False
        if best is None or (candidate.compromise_score, candidate.candidate_id) < (
            best.compromise_score,
            best.candidate_id,
        ):
            best = candidate
    assert best is not None
    best.is_compromise = True
    return best


def parse_key_value(items: Sequence[str], label: str) -> dict[str, float]:
    parsed: dict[str, float] = {}
    for item in items:
        if "=" not in item:
            raise ParetoError(f"invalid {label} {item!r}; expected metric=value")
        key, raw = item.split("=", 1)
        key = key.strip()
        try:
            value = float(raw)
        except ValueError as exc:
            raise ParetoError(f"invalid numeric {label}: {item!r}") from exc
        if not key or value < 0 or not math.isfinite(value):
            raise ParetoError(f"invalid {label}: {item!r}")
        parsed[key] = value
    return parsed


def make_objectives(
    names: Sequence[str],
    maximize: set[str],
    default_epsilon: float,
    metric_epsilon: Mapping[str, float],
) -> list[Objective]:
    objectives: list[Objective] = []
    for name in names:
        stripped = name.strip()
        if stripped:
            objectives.append(
                Objective(
                    name=stripped,
                    maximize=stripped in maximize,
                    epsilon=metric_epsilon.get(stripped, default_epsilon),
                )
            )
    if not objectives:
        raise ParetoError("at least one objective is required")
    unknown = maximize.difference(objective.name for objective in objectives)
    if unknown:
        raise ParetoError(f"--maximize names are not objectives: {', '.join(sorted(unknown))}")
    return objectives


def format_number(value: Any) -> str:
    if not is_number(value):
        return str(value)
    number = float(value)
    if abs(number) >= 10000 or (0 < abs(number) < 0.001):
        return f"{number:.4g}"
    return f"{number:.4f}".rstrip("0").rstrip(".")


def write_outputs(
    output_dir: Path,
    input_path: Path,
    candidates: Sequence[Candidate],
    fronts: Sequence[Sequence[Candidate]],
    compromise: Candidate,
    objectives: Sequence[Objective],
    statistic: str,
    constraints: Sequence[str],
    weights: Mapping[str, float],
    total_rows: int,
    rejected_rows: int,
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        "input": str(input_path),
        "statistic": statistic,
        "total_rows": total_rows,
        "rejected_rows": rejected_rows,
        "constraints": list(constraints),
        "objectives": [
            {"name": objective.name, "direction": "max" if objective.maximize else "min", "epsilon": objective.epsilon}
            for objective in objectives
        ],
        "weights": dict(weights),
        "compromise_candidate": compromise.candidate_id,
        "fronts": [[candidate.candidate_id for candidate in front] for front in fronts],
        "candidates": [candidate.as_json() for candidate in sorted(candidates, key=lambda item: (item.rank, item.candidate_id))],
    }
    (output_dir / "pareto.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    config_keys = [key for key in CONFIG_FIELDS if any(key in candidate.config for candidate in candidates)]
    score_keys = [objective.name for objective in objectives]
    with (output_dir / "summary.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["candidate_id", "rank", "samples", "is_compromise", "compromise_score", *config_keys, *score_keys],
        )
        writer.writeheader()
        for candidate in sorted(candidates, key=lambda item: (item.rank, item.compromise_score, item.candidate_id)):
            row: dict[str, Any] = {
                "candidate_id": candidate.candidate_id,
                "rank": candidate.rank,
                "samples": candidate.samples,
                "is_compromise": candidate.is_compromise,
                "compromise_score": candidate.compromise_score,
                **candidate.config,
                **candidate.scores,
            }
            writer.writerow(row)

    lines = [
        "# MaccyZig Pareto report",
        "",
        f"- Input rows: {total_rows}",
        f"- Feasible rows: {total_rows - rejected_rows}",
        f"- Candidate configurations: {len(candidates)}",
        f"- Aggregation statistic: `{statistic}`",
        f"- Rank-1 frontier size: {len(fronts[0])}",
        f"- Balanced compromise: **{compromise.candidate_id}**",
    ]
    if constraints:
        lines.append(f"- Constraints: {', '.join(f'`{item}`' for item in constraints)}")
    lines.extend(["", "## Rank-1 frontier", ""])
    headers = ["candidate", "runs", *[objective.name for objective in objectives], "compromise"]
    lines.append("| " + " | ".join(headers) + " |")
    lines.append("| " + " | ".join(["---"] * len(headers)) + " |")
    for candidate in sorted(fronts[0], key=lambda item: (item.compromise_score, item.candidate_id)):
        values = [
            candidate.candidate_id,
            str(candidate.samples),
            *[format_number(candidate.scores[objective.name]) for objective in objectives],
            "yes" if candidate.is_compromise else "",
        ]
        lines.append("| " + " | ".join(values) + " |")

    lines.extend(["", "## All candidates", ""])
    headers = ["rank", "candidate", *[objective.name for objective in objectives]]
    lines.append("| " + " | ".join(headers) + " |")
    lines.append("| " + " | ".join(["---"] * len(headers)) + " |")
    for candidate in sorted(candidates, key=lambda item: (item.rank, item.compromise_score, item.candidate_id)):
        values = [
            str(candidate.rank),
            candidate.candidate_id,
            *[format_number(candidate.scores[objective.name]) for objective in objectives],
        ]
        lines.append("| " + " | ".join(values) + " |")
    lines.extend(
        [
            "",
            "The compromise is an augmented normalized Chebyshev choice within rank 1. It is a decision aid, not a replacement for the frontier or correctness gates.",
            "",
        ]
    )
    (output_dir / "report.md").write_text("\n".join(lines), encoding="utf-8")


def analyze(args: argparse.Namespace) -> int:
    input_path = Path(args.input)
    rows = load_jsonl(input_path, args.poll_quantile)
    metric_epsilon = parse_key_value(args.epsilon_metric, "epsilon override")
    weights = parse_key_value(args.weight, "weight")
    names = [name.strip() for name in args.objectives.split(",") if name.strip()]
    maximize = {name.strip() for name in args.maximize.split(",") if name.strip()}
    objectives = make_objectives(names, maximize, args.epsilon, metric_epsilon)
    constraints = [parse_constraint(expression) for expression in args.require]
    candidates, rejected_rows = aggregate(rows, objectives, args.stat, constraints)
    fronts = rank_fronts(candidates, objectives)
    compromise = choose_compromise(fronts[0], objectives, weights)
    write_outputs(
        Path(args.output_dir),
        input_path,
        candidates,
        fronts,
        compromise,
        objectives,
        args.stat,
        args.require,
        weights,
        len(rows),
        rejected_rows,
    )
    print(f"rank-1 frontier: {', '.join(candidate.candidate_id for candidate in fronts[0])}")
    print(f"balanced compromise: {compromise.candidate_id}")
    print(f"report: {Path(args.output_dir) / 'report.md'}")
    return 0


def self_test() -> int:
    assert quantile([0.0, 10.0], 0.95) == 9.5
    derived = derive_metrics(
        {
            "candidate_id": "x",
            "poll_interval_ms": 500,
            "insert_1m_us": 800,
            "refresh_us": 100,
            "search_p95_us": 300,
            "bench_peak_rss_bytes": 32 * 1024 * 1024,
            "binary_bytes": 100 * 1024,
        },
        0.95,
    )
    assert abs(derived["copy_to_ready_ms"] - 475.9) < 1e-9
    assert derived["poll_ticks_per_s"] == 2.0
    assert parse_constraint("images==true") == ("images", "==", True)

    objectives = [Objective("latency", epsilon=0.01), Objective("memory", epsilon=0.01)]
    a = Candidate("a", {}, 3, {}, {"latency": 1.0, "memory": 2.0})
    b = Candidate("b", {}, 3, {}, {"latency": 2.0, "memory": 1.0})
    c = Candidate("c", {}, 3, {}, {"latency": 3.0, "memory": 3.0})
    fronts = rank_fronts([a, b, c], objectives)
    assert {item.candidate_id for item in fronts[0]} == {"a", "b"}
    assert fronts[1][0].candidate_id == "c"
    compromise = choose_compromise(fronts[0], objectives, {"latency": 1.0, "memory": 1.0})
    assert compromise.candidate_id in {"a", "b"}
    print("pareto.py self-test passed")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", help="JSONL file containing repeated measurements")
    parser.add_argument("--output-dir", default="benchmarks/reports/latest", help="report output directory")
    parser.add_argument("--objectives", default=",".join(DEFAULT_OBJECTIVES), help="comma-separated objective metrics")
    parser.add_argument("--maximize", default="", help="comma-separated objectives to maximize; all others minimize")
    parser.add_argument("--stat", choices=("min", "median", "mean", "p95", "max", "ucb95"), default="p95")
    parser.add_argument("--epsilon", type=float, default=0.02, help="default relative epsilon for material dominance")
    parser.add_argument("--epsilon-metric", action="append", default=[], metavar="METRIC=VALUE", help="per-objective epsilon override")
    parser.add_argument("--require", action="append", default=[], metavar="EXPR", help="feasibility constraint, e.g. images==true")
    parser.add_argument("--weight", action="append", default=[], metavar="METRIC=VALUE", help="compromise weight")
    parser.add_argument("--poll-quantile", type=float, default=0.95, help="quantile used for uniform polling-detection delay")
    parser.add_argument("--self-test", action="store_true", help="run deterministic analyzer tests")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        if args.self_test:
            return self_test()
        if not args.input:
            parser.error("--input is required unless --self-test is used")
        if args.epsilon < 0 or not math.isfinite(args.epsilon):
            raise ParetoError("--epsilon must be a finite non-negative value")
        if not 0.0 <= args.poll_quantile <= 1.0:
            raise ParetoError("--poll-quantile must be in [0, 1]")
        return analyze(args)
    except ParetoError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
