# MaccyZig performance experiments

The benchmark directory contains the candidate design and generated-output locations for the multi-objective performance workflow.

- `pareto-space.json`: explicit release/runtime candidates, repetitions, feasibility constraints, objectives, and compromise weights.
- `results/`: ignored raw JSONL measurements, one row per measured repetition.
- `reports/`: ignored Pareto JSON, CSV, and Markdown reports.
- [`../docs/performance-pareto.md`](../docs/performance-pareto.md): mathematical model, measurement scope, protocol, and frontier-expansion roadmap.

## Measurement boundary

The harness directly measures the CLI storage/search workload, peak RSS of that workload, binary size, and database size. `copy_to_ready_ms` combines those measured components with an analytical polling-delay term; it is a model-derived scenario metric, not a direct GUI stopwatch measurement.

The current AppKit GUI still creates a 500 ms timer with 100 ms tolerance. Candidate `poll_interval_ms` values therefore represent policy scenarios until that interval is wired into the GUI runtime and validated with signposts. Likewise, `images` and `max_blob_mib` are capability/feasibility labels in this storage benchmark; live capture, preview decode, and paste-replay memory require separate AppKit measurements.

Inspect the design without building:

```sh
bash scripts/benchmark-pareto.sh --list
```

Run the macOS benchmark and analysis:

```sh
bash scripts/benchmark-pareto.sh
```

Run the analyzer's platform-independent self-test:

```sh
python3 scripts/pareto.py --self-test
```

Do not merge result files from different machines, macOS builds, Zig revisions, or power states into one frontier. Every raw row records machine and toolchain metadata so accidental pooling can be detected during review.
