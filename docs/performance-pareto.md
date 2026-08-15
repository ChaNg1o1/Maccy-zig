# Performance model and Pareto-frontier workflow

This document turns MaccyZig performance work into a constrained multi-objective optimization problem. The target is not one maximum benchmark score. The target is the set of configurations and code changes that are non-dominated across user-visible latency, search speed, memory, idle wakeups, binary size, and retained product capability.

The existing storage benchmark is useful but incomplete. A fast SQLite insert does not imply a fast copy-to-visible path, a responsive search UI, low idle energy, or bounded image-preview memory. The workflow below separates these components, measures them repeatedly, and then computes a robust Pareto frontier.

## 1. Decision variables and workload variables

For the initial parameter sweep, define a candidate as

\[
x=(o,N,\Delta,B_{\max},I),
\]

where:

- \(o\) is the Zig optimization mode: `ReleaseFast`, `ReleaseSmall`, or `ReleaseSafe`;
- \(N\) is the unpinned history cap;
- \(\Delta\) is the pasteboard polling interval in milliseconds;
- \(B_{\max}\) is the maximum accepted size of one clipboard blob;
- \(I\in\{0,1\}\) indicates whether image flavors are retained.

The workload is described separately:

- \(B\): total captured payload bytes;
- \(K\): number of pasteboard flavors/blobs;
- \(R\): rows returned by a refresh;
- \(V\): visible rows plus virtualization overscan;
- \(q\): search-query length and selectivity;
- \(W,H\): decoded image dimensions;
- \(r\): repeated benchmark runs per candidate.

Separating decision variables from workload variables avoids a common modeling error: treating a result from one 1 KiB text copy as if it described 16 MiB images, 2,000-row search, and the idle daemon simultaneously.

## 2. Latency and throughput model

### 2.1 Polling detection delay

With fixed periodic polling and a copy event independent of timer phase, detection delay is approximately

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

At the current \(\Delta=500\text{ ms}\), the modeled p95 detection component alone is

\[
Q_{.95}(D_{500})=475\text{ ms}.
\]

This is orders of magnitude larger than the recorded sub-millisecond SQLite insert cost for a 1 MiB payload. Consequently, further micro-optimizing storage cannot materially improve copy-to-visible p95 unless the polling policy is also addressed.

The model deliberately treats wakeups rather than raw CPU percentage as the first idle proxy. Real energy validation should add `powermetrics` measurements because timer coalescing, E/P-core placement, and AppKit work per tick are hardware- and OS-dependent.

### 2.2 Capture and persistence

A first-order capture model is

\[
T_{capture}(B,K)
\approx \alpha_0+\alpha_B B+\alpha_K K+T_{sqlite}(B,K),
\]

where the linear byte term covers pasteboard snapshot copies, SHA-256, and blob binding. The current path is intentionally bounded by \(B_{\max}\), so peak work per flavor cannot grow without limit.

For throughput reporting,

\[
\text{capture ops/s}=\frac{1000}{T_{capture,ms}}.
\]

The benchmark records insert latency at 64 B, 1 KiB, 64 KiB, and 1 MiB. These points allow a simple segmented fit and expose nonlinearities from page allocation, WAL growth, checkpointing, or blob-copy amplification. Do not extrapolate the 1 MiB slope to 16 MiB without measuring that range.

### 2.3 Refresh and search

The refresh path can be decomposed as

\[
T_{refresh}=T_{sql}(N,q)+T_{marshal}(R)+T_{ui}(V).
\]

Current substring search has a pattern equivalent to

```sql
LIKE '%' || query || '%'
```

so a conventional B-tree cannot seek by the leading search term. The dominant database component is therefore approximately

\[
T_{sql}(N,q)=\Theta(N)
\]

for the bounded history set, with a coefficient affected by title/app lengths and query selectivity.

The Zig/C/Objective-C boundary duplicates row metadata, making

\[
T_{marshal}(R)=\Theta(R),
\qquad
M_{marshal}(R)=\Theta(R).
\]

The AppKit list is virtualized, so view construction and layout are closer to

\[
T_{ui}(V)=\Theta(V),
\]

not \(\Theta(N)\). This distinction is important: an optimization that only reduces view count cannot remove the SQL scan or full row snapshot cost.

The UI also debounces search by about 30 ms. End-to-end keystroke latency is therefore approximately

\[
L_{key\rightarrow visible}
\approx 30\text{ ms}+T_{sql}+T_{marshal}+T_{ui}+T_{queue},
\]

where \(T_{queue}\) captures waiting behind capture/prune work on the serial database queue.

The harness measures a warm hit query and a warm miss query using the app-shaped SQL and defines `search_ms` as the worse p95. A live UI trace remains necessary to measure debounce, queueing, cross-language marshalling, and drawing together.

### 2.4 User-facing copy-to-ready latency

For the automated screening workload, use a conservative component sum:

\[
L_{copy\rightarrow ready,p95}
=0.95\Delta
+Q_{.95}(T_{capture,1MiB})
+Q_{.95}(T_{refresh}).
\]

The 1 MiB payload is representative rather than universal. Text-heavy deployments should add a text objective; image-heavy deployments should add 4 MiB and 16 MiB capture/preview objectives. The component sum is intentionally auditable: each term can be improved and remeasured independently.

Popup opening and paste replay should be added as separate objectives when instrumented:

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

- \(M_0\) is the AppKit/Zig process baseline;
- \(M_{sqlite}\) includes resident database pages, WAL state, and statement objects;
- \(R\,m_{row}\) is the full metadata snapshot returned to Objective-C;
- \(V\,m_{view}\) is the virtualized visible-cell graph;
- \(M_{preview}\) is cached encoded and decoded preview data;
- \(A(B,K)\) is transient allocation amplification during capture, preview, and paste replay.

The database currently requests an approximately 32 MiB SQLite cache and a 64 MiB mmap window. The mmap value is address space, not guaranteed resident memory. The image-preview `NSCache` has a 64 MiB cost limit based on encoded byte length; decoded image surfaces can be larger.

For an RGBA-like decoded image,

\[
M_{decoded}\approx4WH,
\]

before scale-factor duplication, framework caches, and backing surfaces. A compressed 4 MiB screenshot can therefore occupy tens of MiB after decode.

The current paste replay path can keep multiple representations live: SQLite page/blob memory, a Zig-owned copy, and Objective-C `NSData`/pasteboard objects. Ignoring the pasteboard server, transient memory is still

\[
A(B,K)=\Theta(B)
\]

with an amplification factor greater than one. Any zero-copy change must make buffer lifetime explicit; a lower RSS number is not acceptable if it introduces use-after-free or corrupts clipboard flavors.

`bench_peak_rss_mib` is peak RSS of the CLI storage workload. It is suitable for comparing build/storage candidates, but it does not replace these live-app measurements:

- steady-state idle RSS after launch;
- popup-open peak RSS;
- image hover/decode peak RSS;
- 1/4/16 MiB paste replay peak RSS;
- memory recovered after preview-cache pressure.

## 4. Objective vector and feasibility constraints

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

The corresponding fields are:

```text
copy_to_ready_ms
search_ms
bench_peak_rss_mib
poll_ticks_per_s
binary_kib
```

For a product-parity frontier, impose

\[
I=1,\qquad B_{\max}\ge16\text{ MiB},\qquad N\ge500.
\]

Non-numeric feasibility gates are mandatory:

- concealed/transient clipboard writes are never persisted;
- a failed persistence attempt does not consume the change count;
- pinned entries survive capacity and age pruning;
- rich clipboard flavors and multi-file semantics remain correct;
- unit tests and package smoke tests pass;
- no main-thread blocking regression is introduced.

The candidate space also contains 4 MiB and text-only modes. They quantify the resource price of capability, but the default constraints prevent them from appearing as apparently superior yet functionally weaker product-parity points.

## 5. Robust Pareto analysis

For minimization objectives, candidate \(a\) classically dominates \(b\) when

\[
f_j(a)\le f_j(b)\quad\forall j,
\qquad
f_k(a)<f_k(b)\quad\text{for at least one }k.
\]

Benchmarks on laptops are noisy. The analyzer uses relative epsilon dominance. Candidate \(a\) is materially no worse than \(b\) on objective \(j\) when

\[
f_j(a)\le f_j(b)
+\epsilon_j\max\left(|f_j(a)|,|f_j(b)|\right),
\]

and it must be better by more than that tolerance on at least one objective. The default design uses \(\epsilon=3\%\). This prevents sub-noise differences from creating a false frontier.

Each candidate is aggregated across repeated trials using one of:

- median;
- p95;
- mean;
- max;
- upper confidence bound

\[
UCB_{.95}=\bar y+1.645\frac{s}{\sqrt r}.
\]

The report also retains standard deviation, median absolute deviation, and robust sigma

\[
\hat\sigma_{robust}=1.4826\,MAD.
\]

Rank 1 is the feasible non-dominated set. Higher ranks are successive non-dominated layers, not a scalar leaderboard.

When one default must be selected, the analyzer uses an augmented normalized Chebyshev compromise within rank 1:

\[
C(x)=\max_j w_jz_j(x)+0.05\sum_jw_jz_j(x),
\]

where \(z_j\in[0,1]\) is normalized regret from the best frontier value. This favors balanced worst-objective regret while retaining a small tie-breaking penalty. It is a decision aid, not a replacement for the frontier.

## 6. Experimental protocol

Absolute comparisons must use the same machine, macOS build, Zig revision, power state, and thermal regime.

1. Close indexing-heavy workloads, browsers, and other clipboard managers when practical.
2. Keep the machine on AC power and record Low Power Mode.
3. Build every optimization mode once; benchmark the preserved executable rather than rebuilding per trial.
4. Warm every candidate before measured trials.
5. Randomize candidate order across measured repetitions to decorrelate candidates from thermal drift and noisy neighbors.
6. Use a fresh SQLite database for each repetition.
7. Use 7–11 repetitions for screening and about 30 for release decisions or small claimed improvements.
8. Inspect p95, MAD, and standard deviation. A nominal delta below noise is not evidence.
9. Do not merge result rows from different hardware/OS/toolchain cohorts into one frontier.
10. Run correctness tests after every implementation change; run real GUI traces for UI claims.

Each JSONL row records candidate configuration, hardware, macOS build, Zig version, git commit, raw timings, peak RSS, binary size, and database size.

## 7. Running the workflow

Inspect the 12 default candidates without building:

```sh
bash scripts/benchmark-pareto.sh --list
```

Run the default macOS screening experiment:

```sh
bash scripts/benchmark-pareto.sh
```

Run a higher-confidence experiment:

```sh
bash scripts/benchmark-pareto.sh --runs 30 --warmups 3
```

Use a custom space and output cohort:

```sh
bash scripts/benchmark-pareto.sh \
  --space /path/to/space.json \
  --output benchmarks/results/m5-pro.jsonl \
  --report-dir benchmarks/reports/m5-pro
```

Reanalyze existing measurements:

```sh
python3 scripts/pareto.py \
  --input benchmarks/results/m5-pro.jsonl \
  --output-dir benchmarks/reports/product-parity \
  --require 'images==true' \
  --require 'max_blob_mib>=16' \
  --require 'max_items>=500' \
  --weight copy_to_ready_ms=2 \
  --weight search_ms=2 \
  --weight bench_peak_rss_mib=1 \
  --weight poll_ticks_per_s=1 \
  --weight binary_kib=0.5
```

Validate the analyzer and candidate expansion:

```sh
python3 scripts/pareto.py --self-test
bash -n scripts/benchmark-pareto.sh
bash scripts/benchmark-pareto.sh --list
```

Generated outputs are:

- raw JSONL: one row per measured repetition;
- `summary.csv`: configuration, rank, compromise score, and objective values;
- `pareto.json`: full statistics, fronts, dominators, and metadata;
- `report.md`: compact decision table.

## 8. Structural changes that can move the frontier

A parameter sweep only finds the best points available in the current architecture. The following changes can create new frontier points.

### 8.1 Adaptive polling

Use a fast interval \(\Delta_h\) during a short hot window after user/copy activity and a slow interval \(\Delta_c\) while cold. If \(\rho\) is the share of copy events occurring hot and \(\pi\) is the share of wall time spent hot,

\[
\mathbb E[D]
\approx\frac12\left(\rho\Delta_h+(1-\rho)\Delta_c\right),
\]

\[
W\approx\frac{\pi}{\Delta_h}+\frac{1-\pi}{\Delta_c}.
\]

When copy events cluster in interaction bursts, \(\rho\gg\pi\), adaptive polling can reduce both observed latency and long-run wakeups relative to a single static interval. Validate this from an anonymized trace of change timestamps rather than assuming burstiness.

### 8.2 Asynchronous image preview

Image hover currently synchronizes with the serial database queue before decode. Queue wait can therefore become a main-thread stall. Move blob read and decode off the main thread, attach a row/generation token, and discard stale completions. Add hover-to-preview p95, main-thread blocked time, and preview peak RSS as objectives.

### 8.3 Reduce blob-copy amplification

Profile capture, preview, and paste replay separately at 1, 4, and 16 MiB. Remove only copies whose ownership/lifetime is explicit. Acceptance requires lower p95 and peak RSS with identical flavor fidelity and no memory-safety regression.

### 8.4 Search indexing after the crossover

At \(N\le500\), a substring scan may be simpler and faster than maintaining an index. At larger \(N\), compare current `LIKE`, FTS5, and trigram/token approaches on

\[
\Delta T_{read}(N,q),\quad
\Delta T_{write}(B),\quad
\Delta S_{db},\quad
\Delta M_{RSS}.
\]

Adopt indexing only beyond the measured crossover \(N^*\), or enable it conditionally. An index that helps 2,000-row search but regresses every default capture may not expand the product-parity frontier.

### 8.5 Incremental row snapshots

Preserve immutable row objects by ID/hash and apply inserts, reorder operations, pin changes, and deletions as diffs. This targets \(T_{marshal}(R)\) and transient memory without changing SQLite correctness semantics.

## 9. Shipping rule

A performance change is accepted only when all correctness gates pass and one of the following is true on repeated target-machine measurements:

1. it materially dominates the current shipping candidate under the agreed epsilon; or
2. it adds a meaningful new point to the feasible Pareto frontier for a documented product mode.

A scalar win that hides a regression in another objective is not an optimization. A result smaller than run-to-run noise is not evidence. Do not label a candidate “Pareto optimal” until target-machine JSONL data has actually been collected and analyzed.
