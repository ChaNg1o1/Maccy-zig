# MaccyZig performance experiments

The benchmark directory contains the candidate design and generated-output locations for the multi-objective performance workflow.

- `pareto-space.json`: explicit release/runtime candidates, repetitions, feasibility constraints, objectives, and compromise weights.
- `results/`: ignored raw JSONL measurements, one row per measured repetition.
- `reports/`: ignored Pareto JSON, CSV, and Markdown reports.
- [`../docs/performance-pareto.md`](../docs/performance-pareto.md): mathematical model, measurement scope, protocol, and frontier-expansion roadmap.

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
