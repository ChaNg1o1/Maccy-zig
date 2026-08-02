# Profiling flows on Apple Silicon macOS

Every flow assumes an optimized build with symbols (see SKILL.md Part 1).

---

## Flow A: quick statistics

The x86 skill used `perf stat`; the macOS equivalents are `hyperfine` for
wall clock and `/usr/bin/time -l` for OS-level counters.

```bash
# Wall clock with statistical rigor (min 10 runs, warmup):
hyperfine --warmup 3 './zig-out/bin/app bench'

# A/B comparison — THE primary verification tool for any optimization:
hyperfine --warmup 3 './app-before bench' './app-after bench'

# OS counters: max RSS, page faults, context switches, instructions retired:
/usr/bin/time -l ./zig-out/bin/app bench
```

Interpretation:
- `instructions retired / cycles elapsed` from `time -l` gives IPC. M-series
  P-cores sustain very wide execution; IPC below ~1.5 on compute-heavy code
  suggests dependency chains or cache misses, IPC above 4 means the core is
  well fed.
- High `involuntary context switches` on a short benchmark → machine noise
  or QoS demotion to E-cores (see Flow E).
- `maximum resident set size` regressions matter on this unified-memory
  platform: memory pressure evicts other apps' working sets.

If `hyperfine` is missing: `brew install hyperfine`.

---

## Flow B: hotspot profiling

Which functions and lines consume CPU. Two tools, cheapest first.

### B1 — `sample` (no setup, attach to a running process)

```bash
sample <pid-or-name> 10 -file /tmp/sample.txt   # 10 seconds, 1ms interval
```

Read the call-tree; hot leaves appear with the largest self counts. Good
enough to find a hotspot in an already-running GUI app. Symbolication is
automatic for local builds.

### B2 — `xctrace` Time Profiler (headless Instruments)

```bash
# Launch and profile a workload end-to-end:
xcrun xctrace record --template 'Time Profiler' \
    --launch ./zig-out/bin/app --output /tmp/run.trace -- bench

# Attach to a running app instead:
xcrun xctrace record --template 'Time Profiler' \
    --attach <pid> --time-limit 10s --output /tmp/run.trace

# Export the hottest stacks as XML for programmatic reading:
xcrun xctrace export --input /tmp/run.trace \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'
```

Open `.trace` files in Instruments.app for interactive drill-down; prefer
the export path when working non-interactively.

### B3 — CPU Counters template (closest analog to `perf stat -d`)

```bash
xcrun xctrace list templates          # confirm 'CPU Counters' exists
xcrun xctrace record --template 'CPU Counters' --launch ./app --output c.trace
```

Configure events in Instruments (cycles, instructions, L1D/L2 misses, branch
mispredicts). Needs admin once per boot. Use only after Flow B1/B2 located a
hotspot and you need to know *why* it is slow (miss-bound vs dependency-bound).

### Rust extras

`cargo flamegraph` and `samply record ./target/release/app` both work on
macOS and produce interactive flamegraphs; `criterion`/`divan` for
micro-benchmarks. Prefer these over xctrace for pure-Rust CLI work.

---

## Flow C: contention and scaling

There is no `perf c2c` on macOS. Diagnose contention by *differential
measurement*:

1. **Scaling curve.** Run the workload at 1, 2, 4, 8 threads with hyperfine.
   Throughput that flattens or inverts while CPU time grows → contention.
2. **Time Profiler at N threads.** Lock-bound code shows
   `_os_unfair_lock_lock_slow`, `__psynch_mutexwait`, `usleep`, or
   `os_unfair_lock` symbols climbing with thread count.
3. **System Trace template** shows thread states (running/blocked/preempted)
   and which lock blocked whom:
   `xcrun xctrace record --template 'System Trace' ...`
4. **False-sharing hypothesis test.** No HITM counter is exposed, so test
   structurally: pad the suspect fields to 128 bytes (`align(128)` in Zig,
   `#[repr(align(128))]` in Rust, `alignas(128)` in C/ObjC) and re-measure.
   Improvement confirms the diagnosis; then minimize layout as in the
   false-sharing pattern. Cache lines are 128 bytes on Apple Silicon —
   x86-derived 64-byte padding half-fixes the problem.

---

## Flow D: UI responsiveness (GUI apps)

Latency the user feels: popup open, keystroke-to-result, paste delay.

1. **Hang detection.** Instruments 'Hangs' template flags main-thread stalls
   >250ms. For finer budgets use signposts.
2. **Signposts.** Bracket suspect spans with `os_signpost` (ObjC) and view
   them in Instruments 'Points of Interest'; in Zig, call
   `os_signpost_interval_begin/end` through a small C shim. Measure
   event-to-paint, not function time.
3. **Cheap logging fallback.** A monotonic-clock delta printed at the two
   ends of the span (already available as `nowNs()` in this repo) is enough
   for before/after comparison; keep it behind a debug flag.
4. **Main-thread audit.** In the Time Profiler, filter to the main thread
   only. Anything database- or file-shaped there is a finding (see
   main-thread-blocking pattern).

Budgets: 16ms per frame during animation; 100ms for a keystroke response;
anything over 250ms is an OS-level hang.

---

## Flow E: energy and core placement

Background daemons (like a clipboard watcher) are judged on energy, not
throughput.

```bash
# E/P-core residency, frequency, and energy per process (needs sudo):
sudo powermetrics --samplers tasks,cpu_power -i 1000 -n 5 \
    | grep -A2 -i <appname>

# Timer wakeups — the dominant daemon energy cost:
sudo powermetrics --samplers tasks --show-process-energy -i 5000 -n 1
```

Interpretation:
- A polling daemon should run entirely on E-cores at low frequency. If it
  shows P-core residency, look for QoS set too high
  (`QOS_CLASS_USER_INTERACTIVE`/`INITIATED` on background work) or bursts
  large enough to trigger promotion.
- "Idle wakeups" scale with timer frequency. Halving a poll rate halves the
  floor cost; replacing polling with an event source (see polling-to-event
  pattern) drops it to zero.
- Set explicit QoS on GCD queues: `QOS_CLASS_UTILITY` or
  `QOS_CLASS_BACKGROUND` for capture/prune work, so the scheduler keeps it
  off P-cores. Beware priority inversion: if the UI synchronously waits on
  that queue, the wait inherits and defeats the demotion — fix the wait, not
  the QoS.
