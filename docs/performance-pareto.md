# Performance model and Pareto-frontier workflow

MaccyZig performance is a constrained multi-objective optimization problem. The goal is not one maximum benchmark score. The goal is the set of configurations and architectural changes that are non-dominated across user-visible latency, search speed, resident memory, idle wakeups, binary size, and retained product capability.

The existing storage microbenchmark is necessary but insufficient. A fast SQLite insert does not imply a fast copy-to-visible path, a responsive search UI, low idle energy, or bounded image-preview memory. This workflow separates those components, measures them repeatedly, and computes robust capability-conditioned Pareto frontiers.

## 1. Decision and workload variables

For the initial parameter sweep, define a candidate as

\[
x=(o,N,\Delta,B_{\max},I),
\]

where:

- \(o\): Zig optimization mode (`ReleaseFast`, `ReleaseSmall`, `ReleaseSafe`);
- \(N\): unpinned history capacity;
- \(\Delta\): pasteboard polling interval scenario in milliseconds;
- \(B_{\max}\): maximum accepted size of one clipboard blob;
- \(I\in\{0,1\}\): whether image flavors are retained.

The workload is described separately:

- \(B\): captured payload bytes;
- \(K\): number of pasteboard flavors/blobs;
- \(R\): rows returned by a refresh;
- \(V\): visible rows plus virtualization overscan;
- \(q\): search-query length and selectivity;
- \(W,H\): decoded image dimensions;
- \(r\): repeated measured runs per candidate.

This separation prevents a common modeling error: treating a result from a 1 KiB text copy as if it described 16 MiB images, 2,000-row search, and the idle daemon simultaneously.

## 2. Latency and throughput model

### 2.1 Polling detection delay

For an ideal fixed-period poller, with copy events independent of timer phase,

\[
D_{\Delta}\sim U(0,\Delta).
\]

Therefore,

\[
\mathbb E[D_{\Delta}]=\frac{\Delta}{2},
\qquad
Q_p(D_{\Delta})=p\Delta,
\qquad
W_{poll}=\frac{1000}{\Delta}\ \text{ticks/s}.
\]

At \(\Delta=500\text{ ms}\), the idealized p95 phase delay is

\[
Q_{.95}(D_{500})=475\text{ ms}.
\]

This term is much larger than the current sub-millisecond-to-low-millisecond storage work. Further micro-optimizing SQLite cannot materially change copy-to-visible p95 unless polling policy is also addressed.

#### Measurement boundary

`poll_interval_ms` is currently a **policy scenario**, not a directly exercised GUI parameter. The AppKit application still creates a hard-coded 500 ms timer with 100 ms tolerance. The analytical term above does not include timer tolerance, coalescing, run-loop delay, queueing, or display scheduling. A direct GUI latency claim requires wiring the policy into runtime and adding signposts around copy detection, persistence completion, and visible-row application.

Wakeups per second are an initial idle-cost proxy. Real energy validation must add `powermetrics`, timer-wakeup counts, and E/P-core residency on physical target hardware.

### 2.2 Capture and persistence

A first-order capture model is

\[
T_{capture}(B,K)
\approx \alpha_0+\alpha_B B+\alpha_K K+T_{sqlite}(B,K),
\]

where the linear byte term covers pasteboard snapshot copies, SHA-256, and blob binding. The per-flavor limit \(B_{\max}\) bounds worst-case work but does not eliminate multi-representation copy amplification.

For reporting,

\[
\text{capture ops/s}=\frac{1000}{T_{capture,ms}}.
\]

The harness records inserts at 64 B, 1 KiB, 64 KiB, and 1 MiB. These points expose nonlinearities from allocation, WAL growth, page size, checkpointing, and blob copies. Do not extrapolate the 1 MiB slope to 16 MiB without measuring that range.

### 2.3 Refresh and search

The refresh path is decomposed as

\[
T_{refresh}=T_{sql}(N,q)+T_{marshal}(R)+T_{ui}(V).
\]

Current substring search has the shape

```sql
LIKE '%' || query || '%'
```

so a conventional B-tree cannot seek by a leading term. For the bounded history set,

\[
T_{sql}(N,q)=\Theta(N)
\]

up to coefficients determined by title/app lengths, cache state, and selectivity.

The Zig/C/Objective-C boundary duplicates row strings, so

\[
T_{marshal}(R)=\Theta(R),
\qquad
M_{marshal}(R)=\Theta(R).
\]

The AppKit row list is virtualized, making visible view construction approximately

\[
T_{ui}(V)=\Theta(V)
\]

rather than \(\Theta(N)\). View virtualization therefore does not remove the SQL scan or full row snapshot cost.

The UI debounces search by about 30 ms. End-to-end keystroke latency is approximately

\[
L_{key\rightarrow visible}
\approx 30\text{ ms}+T_{sql}+T_{marshal}+T_{ui}+T_{queue},
\]

where \(T_{queue}\) is waiting behind capture/prune work on the serial database queue.

The automated harness measures warm hit and miss queries with the app-shaped SQL and defines `search_ms` as the worse p95. Live AppKit traces remain necessary for debounce, queueing, marshalling, layout, and display together.

### 2.4 Modeled copy-to-ready latency

The screening metric is an auditable component model:

\[
L_{copy\rightarrow ready,p95}
=0.95\Delta
+Q_{.95}(T_{capture,1MiB})
+Q_{.95}(T_{refresh}).
\]

`copy_to_ready_ms` is therefore **model-derived**, not a direct GUI stopwatch result. The 1 MiB payload is representative, not universal. Text-heavy and image-heavy profiles should add separate objectives at 1 KiB, 4 MiB, and 16 MiB.

Additional user-visible paths should be measured independently:

\[
L_{popup}=T_{hotkey}+T_{activation}+T_{refresh}+T_{render},
\]

\[
L_{paste}=T_{blob\ read}+T_{pasteboard\ write}+T_{event\ synthesis}.
\]

## 3. Memory model

A source-level resident-memory decomposition is

\[
M_{RSS}
\approx M_0+M_{sqlite}+R\,m_{row}+V\,m_{view}+M_{preview}+A(B,K),
\]

where:

- \(M_0\): AppKit/Zig process baseline;
- \(M_{sqlite}\): resident database pages, WAL state, and statements;
- \(R\,m_{row}\): full row metadata snapshot;
- \(V\,m_{view}\): virtualized visible-cell graph;
- \(M_{preview}\): encoded and decoded preview cache;
- \(A(B,K)\): transient allocation amplification during capture, preview, and replay.

SQLite currently requests an approximately 32 MiB cache and a 64 MiB mmap window. The mmap setting is address space, not guaranteed resident memory. The image-preview `NSCache` has a 64 MiB cost limit based on encoded byte length; decoded surfaces can be much larger.

For an RGBA-like decoded image,

\[
M_{decoded}\approx4WH,
\]

before scale-factor duplication, framework caches, and backing surfaces. A compressed screenshot can therefore consume tens of MiB after decode.

The paste replay path may simultaneously hold SQLite pages/blob memory, a Zig-owned copy, and Objective-C/pasteboard representations. Ignoring the pasteboard server,

\[
A(B,K)=\Theta(B)
\]

with an amplification factor greater than one. Any zero-copy change must make ownership and buffer lifetime explicit.

`bench_peak_rss_mib` is peak RSS of the CLI storage workload. It is useful for build/storage comparisons but cannot substitute for live measurements of:

- idle RSS after launch;
- popup-open peak RSS;
- 1/4/16 MiB image hover and decode;
- paste replay peak RSS;
- memory recovery after preview-cache pressure.

## 4. Objective vector and capability-conditioned feasibility

The default minimization vector is

\[
f(x)=\left[
L_{copy\rightarrow ready,p95},
T_{search,p95},
M_{bench,p95},
W_{poll},
S_{binary}
\right].
\]

It maps to:

```text
copy_to_ready_ms
search_ms
bench_peak_rss_mib
poll_ticks_per_s
binary_kib
```

### 4.1 Default 500-item product frontier

The default product-parity frontier fixes equivalent capacity:

\[
I=1,
\qquad B_{\max}\ge16\text{ MiB},
\qquad N=500.
\]

Fixing \(N\) matters. If 500- and 2,000-item modes are placed in one minimization-only frontier, the smaller history is favored simply because it does less work. That is not equivalent product capability.

### 4.2 Deep-history frontier

Analyze the 2,000-item mode separately with

\[
I=1,
\qquad B_{\max}\ge16\text{ MiB},
\qquad N=2000.
\]

If a single cross-capability frontier is required, add history capacity as a maximize objective or define an explicit utility function for retained history. Do not treat capacity as free metadata.

The candidate set also includes 4 MiB and text-only modes. They quantify the resource price of reduced capability but are excluded from product-parity fronts.

### 4.3 Correctness gates

Non-numeric feasibility constraints are mandatory:

- concealed/transient clipboard writes are never persisted;
- failed persistence does not consume the change count;
- pinned entries survive capacity and age pruning;
- rich clipboard flavors and multi-file semantics remain correct;
- tests and package smoke checks pass;
- no main-thread blocking regression is introduced.

## 5. Robust Pareto analysis

For minimization objectives, \(a\) classically dominates \(b\) when

\[
f_j(a)\le f_j(b)\quad\forall j,
\qquad
f_k(a)<f_k(b)\quad\text{for at least one }k.
\]

Laptop benchmarks are noisy. The analyzer uses relative epsilon dominance. Candidate \(a\) is materially no worse than \(b\) on objective \(j\) when

\[
f_j(a)\le f_j(b)
+\epsilon_j\max\left(|f_j(a)|,|f_j(b)|\right),
\]

and must be better by more than that tolerance on at least one objective. The default screening value is \(\epsilon=3\%\).

Each candidate can be aggregated by median, p95, mean, maximum, or

\[
UCB_{.95}=\bar y+1.645\frac{s}{\sqrt r}.
\]

The report retains standard deviation, median absolute deviation, and

\[
\hat\sigma_{robust}=1.4826\,MAD.
\]

Rank 1 is the feasible non-dominated set; higher ranks are successive non-dominated layers.

When one default must be selected, the analyzer uses an augmented normalized Chebyshev compromise within rank 1:

\[
C(x)=\max_j w_jz_j(x)+0.05\sum_jw_jz_j(x),
\]

where \(z_j\in[0,1]\) is normalized regret from the best frontier value. This is a decision aid, not a replacement for the frontier.

## 6. Experimental protocol

Absolute comparisons must use one hardware/OS/toolchain cohort.

1. Close indexing-heavy workloads, browsers, and competing clipboard managers when practical.
2. Keep a physical Mac on AC power and record Low Power Mode and thermal state.
3. Build each optimization mode once and preserve the exact executable.
4. Warm every candidate before measured trials.
5. Randomize measured candidate order to decorrelate thermal drift and noisy neighbors.
6. Use a fresh SQLite database per repetition.
7. Use 7–11 repetitions for ordinary screening and about 30 for release decisions or small claimed improvements.
8. Inspect p95, MAD, standard deviation, and UCB95; a delta below noise is not evidence.
9. Do not pool different machines, macOS builds, Zig revisions, or power states.
10. Run correctness tests after every implementation change and real GUI traces for UI claims.

The GitHub-hosted three-run screening is a pipeline validation and large-effect detector, not release evidence.

Each JSONL row records configuration, hardware, macOS build, Zig version, git commit, raw timings, peak RSS, binary size, and database size.

## 7. Running the workflow

Inspect candidates without building:

```sh
bash scripts/benchmark-pareto.sh --list
```

Run the default macOS experiment:

```sh
bash scripts/benchmark-pareto.sh
```

Run a higher-confidence experiment:

```sh
bash scripts/benchmark-pareto.sh --runs 30 --warmups 3
```

Use a named cohort:

```sh
bash scripts/benchmark-pareto.sh \
  --output benchmarks/results/m5-pro.jsonl \
  --report-dir benchmarks/reports/m5-pro
```

Reanalyze the default 500-item frontier:

```sh
python3 scripts/pareto.py \
  --input benchmarks/results/m5-pro.jsonl \
  --output-dir benchmarks/reports/product-500 \
  --require 'images==true' \
  --require 'max_blob_mib>=16' \
  --require 'max_items==500'
```

Reanalyze deep history separately:

```sh
python3 scripts/pareto.py \
  --input benchmarks/results/m5-pro.jsonl \
  --output-dir benchmarks/reports/product-2000 \
  --require 'images==true' \
  --require 'max_blob_mib>=16' \
  --require 'max_items==2000'
```

Validate the tooling:

```sh
python3 scripts/pareto.py --self-test
python3 scripts/benchmark_runner.py --self-test
bash -n scripts/benchmark-pareto.sh
bash scripts/benchmark-pareto.sh --list
```

Generated outputs are:

- raw JSONL: one row per measured repetition;
- `summary.csv`: configuration, rank, compromise score, and objectives;
- `pareto.json`: statistics, fronts, dominators, and metadata;
- `report.md`: compact decision table.

The repository's first macOS screening and its limitations are recorded in [`../benchmarks/initial-macos-screening.md`](../benchmarks/initial-macos-screening.md).

## 8. Structural changes that can expand the frontier

### 8.1 Adaptive polling

Use a fast interval \(\Delta_h\) during a short active window and a slow interval \(\Delta_c\) while cold. If \(\rho\) is the share of copy events occurring hot and \(\pi\) is the wall-time share spent hot,

\[
\mathbb E[D]
\approx\frac12\left(\rho\Delta_h+(1-\rho)\Delta_c\right),
\]

\[
W\approx\frac{1000\pi}{\Delta_h}
+\frac{1000(1-\pi)}{\Delta_c}.
\]

When copy events cluster in interaction bursts, \(\rho\gg\pi\), adaptive polling can reduce observed latency and long-run wakeups together. Validate burstiness from anonymized change timestamps instead of assuming it.

### 8.2 Asynchronous image preview

Image hover currently synchronizes with the serial database queue before decode. Move blob read and decode off the main thread, attach row/generation tokens, and discard stale completions. Add hover-to-preview p95, main-thread blocked time, and preview peak RSS as objectives.

### 8.3 Reduce blob-copy amplification

Profile capture, preview, and replay separately at 1, 4, and 16 MiB. Remove only copies whose ownership and lifetime are explicit. Acceptance requires lower p95 and peak RSS with identical flavor fidelity and no memory-safety regression.

### 8.4 Search indexing after the crossover

At \(N\le500\), a substring scan may be simpler and faster than maintaining an index. At larger \(N\), compare current `LIKE`, FTS5, and trigram/token approaches on

\[
\Delta T_{read}(N,q),
\quad \Delta T_{write}(B),
\quad \Delta S_{db},
\quad \Delta M_{RSS}.
\]

Adopt indexing only beyond the measured crossover \(N^*\), or enable it conditionally. An index that helps 2,000-row search but regresses every default capture may not expand the 500-item product frontier.

### 8.5 Incremental row snapshots

Preserve immutable row objects by ID/hash and apply inserts, reorder operations, pin changes, and deletions as diffs. This targets \(T_{marshal}(R)\) and transient memory without weakening SQLite correctness semantics.

## 9. Shipping rule

A performance change is accepted only when all correctness gates pass and one of the following holds on repeated target-machine measurements:

1. it materially dominates the current shipping candidate under the agreed epsilon; or
2. it adds a meaningful new point to the appropriate capability-conditioned Pareto frontier.

A scalar win that hides another objective's regression is not an optimization. A result smaller than run-to-run noise is not evidence. Do not label a candidate “Pareto optimal” until target-machine data has actually been collected and analyzed.
