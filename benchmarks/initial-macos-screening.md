# Initial macOS Pareto screening

Status: preliminary screening evidence, not a release benchmark or a claim of global Pareto optimality.

This report summarizes the first end-to-end run of the performance workflow on GitHub Actions. The raw JSONL and generated reports were uploaded by workflow run `31894531691`, artifact `9249430744`, digest `sha256:624540702bdc5a398d54d18744aae61644ced7a7676f9efea0aa914337c23353`.

## Cohort and protocol

| Field | Value |
| --- | --- |
| Runner | GitHub-hosted `macos-26-arm64` |
| CPU | Apple M1 (Virtual), 3 logical CPUs |
| Memory | 7 GiB |
| macOS | 26.5.2, build 25F84 |
| Zig | 0.16.0 |
| Seed workload | 2,000 synthetic rows per trial |
| Search samples | 200 hit + 200 miss queries per trial |
| Repetitions | 1 warmup + 3 randomized measured runs per candidate |
| Pareto statistic | p95 across measured runs |
| Materiality tolerance | 3% relative epsilon |

Three measured runs are enough to validate the pipeline and identify large effects. They are not enough to establish small performance differences. A release decision should use approximately 30 repetitions on a physical target Mac with controlled power and thermal state.

## Measurement boundary

Storage insertion, refresh SQL, app-shaped search, benchmark-process peak RSS, binary size, and database footprint are directly measured. `copy_to_ready_ms` is a component model:

\[
L_{copy\rightarrow ready,p95}
=0.95\Delta+T_{capture,1MiB}+T_{refresh}.
\]

The polling term is a policy scenario. The current AppKit GUI still uses a hard-coded 500 ms timer with 100 ms tolerance, so the model is not a direct GUI stopwatch trace and does not include tolerance/coalescing delay.

## Default 500-item product frontier

Reanalysis conditions on equal capability: image support enabled, 16 MiB blob cap, and exactly 500 history items. This avoids treating a 500-item product as automatically superior to a 2,000-item product merely because it does less work.

| Candidate | Mode | Poll scenario | Modeled copy-to-ready p95 | Search p95 | Peak RSS | Binary | Poll ticks/s |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `small-balanced` | ReleaseSmall | 500 ms | 476.384 ms | 0.728 ms | 13.652 MiB | 411.492 KiB | 2 |
| `small-responsive` | ReleaseSmall | 250 ms | 238.910 ms | 0.794 ms | 13.622 MiB | 411.492 KiB | 4 |
| `fast-responsive` | ReleaseFast | 250 ms | 239.012 ms | 0.679 ms | 13.702 MiB | 720.602 KiB | 4 |
| `small-efficient` | ReleaseSmall | 1,000 ms | 951.669 ms | 0.889 ms | 13.653 MiB | 411.492 KiB | 1 |
| `fast-efficient` | ReleaseFast | 1,000 ms | 951.440 ms | 0.821 ms | 13.702 MiB | 720.602 KiB | 1 |

Under the configured compromise weights, `small-balanced` is the balanced rank-1 point. It keeps the middle polling policy while reducing binary size substantially. `fast-balanced` is rank 2 because the screening run found no measured-axis benefit large enough to justify its binary and RSS cost relative to `small-balanced`.

The responsive and efficient pairs remain on the frontier because lower modeled latency trades directly against higher polling pressure. Build-mode search differences are small relative to this three-run cohort and should not be overinterpreted.

## ReleaseSmall versus ReleaseFast

To reduce accidental correlation with the modeled poll scenario, measurements from the three 500-item poll candidates were pooled within each build mode, giving nine measured observations per mode.

| Metric, pooled median | ReleaseFast | ReleaseSmall | Small relative to Fast |
| --- | ---: | ---: | ---: |
| 1 MiB insert | 1,324 µs | 1,234 µs | -6.8% |
| Bulk seed per row | 75 µs | 68 µs | -9.3% |
| Refresh query | 90 µs | 86 µs | -4.4% |
| Per-run search p95 | 684 µs | 717 µs | +4.9% |
| Benchmark peak RSS | 13.688 MiB | 13.609 MiB | -0.57% |
| Whole benchmark wall time | 160 ms | 150 ms | -6.25% |
| Binary size | 720.602 KiB | 411.492 KiB | **-42.9%** |

The large, deterministic result is binary size. The observed runtime differences are much smaller and mostly overlap the cohort's run-to-run variation. The screening evidence therefore supports `ReleaseSmall` as the leading default candidate, but not the stronger claim that it is intrinsically faster on every hot path.

`ReleaseSafe` produced a 796.570 KiB binary and did not enter rank 1 on the measured axes. Its safety semantics may still be valuable, but that value is not represented in this performance-only objective vector.

## History-size scaling

The 2,000-item mode is analyzed separately. Both measured candidates are ReleaseFast:

| Candidate | Poll scenario | Modeled copy-to-ready p95 | Search p95 | Refresh p95 | Peak RSS | Poll ticks/s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `fast-deep-history` | 500 ms | 476.600 ms | 3.457 ms | 0.222 ms | 13.733 MiB | 2 |
| `fast-deep-efficient` | 1,000 ms | 951.467 ms | 3.653 ms | 0.207 ms | 13.717 MiB | 1 |

Compared with `fast-balanced` at 500 items and the same 500 ms policy, 2,000-item search p95 is about 4.17× higher and refresh p95 about 2.35× higher. This is consistent with the current substring scan plus row materialization scaling with returned history size. Absolute search latency remains far below the existing 50 ms interaction budget in this synthetic warm-query workload.

The database file size after pruning is not a useful active-row-size metric in this run: SQLite retains its high-water allocation unless vacuumed. Disk footprint should therefore be measured with page counts/freelist counts or a controlled checkpoint/vacuum protocol rather than raw file length alone.

## Dominant signal

For every default policy candidate, the idealized polling phase contributes more than 99% of modeled copy-to-ready p95:

| Policy | Poll component | Total model | Poll share |
| --- | ---: | ---: | ---: |
| 250 ms | 237.5 ms | 238.910 ms | 99.41% |
| 500 ms | 475.0 ms | 476.384 ms | 99.71% |
| 1,000 ms | 950.0 ms | 951.669 ms | 99.82% |

The next structural optimization should therefore target polling policy rather than another microsecond-level SQLite change. A burst-aware adaptive policy is the leading hypothesis: use a short interval during active copy/user windows and a long interval while cold, then validate with an anonymized trace of pasteboard-change timestamps.

## Recommended next experiment order

1. Treat `ReleaseSmall + 500 items + 500 ms` as the provisional balanced candidate.
2. Wire polling interval/tolerance into the GUI runtime and add signposts for copy event, detection, persistence completion, and visible-row application.
3. Compare static 250/500/1,000 ms policies with an adaptive policy using actual copy-event traces and `powermetrics` wakeup/energy data.
4. Run 30 randomized repetitions on at least one physical Apple Silicon target; report median, p95, MAD, and UCB95.
5. Add live AppKit RSS measurements for idle, popup open, 1/4/16 MiB image preview, and paste replay. The current CLI RSS metric cannot expose decoded-image or pasteboard-copy amplification.
6. Evaluate 500- and 2,000-item modes as separate capability-conditioned frontiers. If one combined frontier is required, history capacity must be an explicit maximize objective.

The screening result establishes a useful direction, not a final answer: ReleaseSmall is a strong build candidate, 500 ms is the current balanced modeled policy, and polling architecture dominates the user-latency frontier.
