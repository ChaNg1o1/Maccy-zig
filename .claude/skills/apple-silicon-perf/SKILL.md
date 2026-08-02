---
name: apple-silicon-perf
description: >-
  Profile and fix performance problems on Apple Silicon macOS for Zig, Rust,
  and Objective-C code. Adapted from intel/intel-performance-skills (x86 Linux
  perf) to the Apple toolchain: xctrace/Instruments, sample, hyperfine,
  powermetrics. Flows: (A) quick wall-clock + CPU stats; (B) hotspot profiling;
  (C) contention and scaling diagnosis (128-byte cache lines); (D) UI
  responsiveness / main-thread hangs; (E) energy and E/P-core placement.
  Pattern catalog: serial accumulator, false sharing, per-thread stats,
  mutex-to-rwlock, cold-path annotation, GCD thundering herd, main-thread
  blocking I/O, dispatch_sync on hot path, ObjC hot-loop overhead, SQLite
  checklist, polling-to-event. Use when asked to optimize, profile, or explain
  slowness in this repo or any Zig/Rust/ObjC macOS project; trigger on:
  hotspot, IPC, cache miss, false sharing, scaling, slow, latency, hang,
  energy, battery, Instruments, xctrace.
---

# Apple Silicon performance skill

Structured workflows for finding and fixing CPU performance problems on
Apple Silicon (M1–M4) macOS, for Zig, Rust, and Objective-C codebases.

## Part 1: setup (always check first)

1. **Optimized build with symbols.** Never profile a Debug build.
   - Zig: `zig build -Doptimize=ReleaseFast` (symbols are kept by default;
     add `-Dcpu=native` only if the binary never leaves this machine —
     universal/release binaries must stay on the baseline CPU).
   - Rust: `cargo build --release` with `[profile.release] debug = true` in
     Cargo.toml so Instruments shows source lines.
   - ObjC (this repo): built through `build.zig`; same flag applies.
2. **Grant profiling access.** `xctrace` and Instruments prompt on first run;
   the CPU Counters template needs an admin password once per boot.
3. **Quiet machine.** Close browsers/Spotlight indexing before comparing runs;
   E/P-core migration makes noisy-neighbor variance worse than on x86.

## Part 2: flows

| Flow | Best for | Time |
|------|----------|------|
| **A** — `hyperfine` + `/usr/bin/time -l` | Wall clock, max RSS, page faults, instructions retired | Seconds |
| **B** — `sample` / `xctrace` Time Profiler | Which functions and source lines are hot | Minutes |
| **C** — scaling + contention | Lock contention, false sharing (128-byte lines), thread scaling | Minutes |
| **D** — hangs + signposts | UI stalls, main-thread blocking, popup/keystroke latency | Minutes |
| **E** — `powermetrics` | Energy, E/P-core residency, timer wakeups for background daemons | Minutes |

Commands and interpretation for every flow: read
[references/tools.md](references/tools.md). When in doubt start with Flow A —
it is fast and often answers the question.

## Part 3: pattern catalog

After (or instead of) profiling, match code against the catalog in
[references/patterns.md](references/patterns.md). Quick-match table:

| Signal | Pattern |
|--------|---------|
| Single accumulator updated every loop iteration (`sum += ...`) | Serial accumulator |
| Struct fields written by different threads, no 128-byte separation | False sharing |
| Shared `count += 1` / atomic increment in a hot path | Per-thread stats |
| Mutex guarding a read-mostly lookup | Mutex to rwlock |
| Hot function calls error/logging helpers with no cold hint | Cold-path annotation |
| Blocking I/O, SQLite, or file access on the main thread / UI callback | Main-thread blocking |
| `dispatch_sync` (or semaphore wait) executed per event/per row | dispatch_sync on hot path |
| `objc_msgSend`, NSString bridging, or autorelease churn inside a tight loop | ObjC hot-loop overhead |
| Any SQLite usage — prepare-per-call, missing index, no WAL, SELECT * | SQLite checklist |
| Fixed-interval timer polling for a change that has a notification API | Polling to event |
| GCD broadcast waking all workers for one job | Thundering herd |

Microarchitecture facts (cache-line size, P/E cores, NEON widths, LSE
atomics, unified memory) live in
[references/microarch.md](references/microarch.md) — consult before any
low-level tuning, and cite them instead of x86 numbers.

## Part 4: this repo (Maccy-zig)

Known hot paths, measurement harness, and target budgets for this project:
[references/maccy-zig.md](references/maccy-zig.md). Always measure with the
harness there before and after a change; a change without both numbers is
not an optimization.

## Method (non-negotiable)

1. Measure first (Flow A minimum). 2. Locate with Flow B/C/D. 3. Match a
pattern and apply the smallest fix. 4. Re-measure identically. 5. Revert
anything that does not reproduce an improvement outside noise.
