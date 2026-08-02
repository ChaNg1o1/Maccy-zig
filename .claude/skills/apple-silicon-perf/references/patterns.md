# Performance pattern catalog (Apple Silicon / Zig / Rust / ObjC)

Each pattern: detection signals → fix → verification. Multiple patterns can
co-apply; check all plausible matches. Verify every fix with Flow A
(hyperfine A/B) plus the pattern's own signal.

---

## Serial accumulator

**Detect.** A reduction loop with one accumulator: `sum += a[i] * b[i]`,
running max/min, hash folding. Each iteration depends on the previous one;
the 4 SIMD pipes of a P-core sit idle.

**Fix.** Split into 4–8 independent accumulators, combine after the loop.

```zig
// Zig: let the vectorizer do it, or explicitly:
var acc: [4]@Vector(4, f32) = @splat(@splat(0));
var i: usize = 0;
while (i + 16 <= n) : (i += 16) {
    inline for (0..4) |k| {
        const va: @Vector(4, f32) = a[i + 4 * k ..][0..4].*;
        const vb: @Vector(4, f32) = b[i + 4 * k ..][0..4].*;
        acc[k] += va * vb;
    }
}
// reduce acc[0..4] + scalar tail
```

Rust: `slice.chunks_exact` with 4 accumulators, or `fold` per chunk then
sum; FP reassociation changes results slightly — confirm tolerance first.

**Verify.** Throughput ~2–4x on the loop; IPC rises (Flow B3).

---

## False sharing

**Detect (source).** Struct fields written at high frequency by different
threads with no alignment separation. **Detect (profile).** Flow C: scaling
flattens; Time Profiler shows the writer functions climbing super-linearly
with threads.

**Fix.** Three steps, in order:
1. Generous padding proof: `align(128)` on the struct, pad between contested
   fields to 128 bytes (Apple Silicon line size — not 64).
2. Re-measure. No improvement → wrong diagnosis (true sharing?); stop.
3. Minimize: group fields by writer thread, one 128-byte line per
   write-often group; read-mostly fields may share a line.

Structural alternative: per-thread structs indexed by thread ID, no shared
line at all.

**Verify.** Scaling curve straightens; add a `comptime` size assert (Zig)
or `static_assert` so layout regressions fail the build.

---

## Per-thread stats

**Detect.** Shared counter updated atomically in a hot path:
`hits.fetch_add(1, .monotonic)`, `count += 1` under a lock. Names: count,
total, hits, bytes.

**Fix.** Per-thread (or per-queue) counters on separate 128-byte lines;
aggregate on read. Reading is rare — pay the sum there.

**Verify.** The atomic-increment symbol leaves the profile; scaling
improves.

---

## Mutex to rwlock

**Detect.** A mutex guarding read-mostly data (lookup table, cache, config)
where writes are <25% of acquisitions. Profile shows
`_os_unfair_lock_lock_slow` / `__psynch_mutexwait` with mostly-read critical
sections.

**Fix.** Zig: `std.Thread.RwLock`. Rust: `std::sync::RwLock` or
`parking_lot::RwLock`. ObjC/C: `pthread_rwlock_t`, or restructure to
immutable snapshots swapped atomically (often better than any lock).

**Verify.** Reader threads no longer serialize; System Trace shows blocked
time collapsing.

---

## Cold-path annotation

**Detect.** A hot function whose body branches to error reporting, logging,
or rare-case handling with no hint; the cold code inflates the hot path's
I-cache footprint.

**Fix.** Zig: `@branchHint(.unlikely)` in the cold branch (or `.cold` on
the callee). Rust: `#[cold]` + `#[inline(never)]` on the handler. C/ObjC:
`__builtin_expect` / `__attribute__((cold, noinline))`.

**Verify.** Only measurable in genuinely hot loops — do not scatter hints
speculatively; apply where Flow B shows the function.

---

## Main-thread blocking (GUI)

**Detect.** SQLite calls, file I/O, image decoding, or synchronous IPC
reachable from the main thread: AppKit callbacks, timer handlers, target
actions. Instruments 'Hangs' template flags stalls; Time Profiler filtered
to the main thread shows the culprit directly.

**Fix.** Move the work to a serial background queue with
`QOS_CLASS_UTILITY`; deliver results back with `dispatch_async` to main.
Never `dispatch_sync` from main to the worker (that recreates the block —
and inverts QoS). For queries, snapshot results into a plain value array
the UI reads without touching the database.

**Verify.** Hangs disappear; main-thread profile shows only layout/drawing.

---

## dispatch_sync on hot path

**Detect.** `dispatch_sync`, `dispatch_semaphore_wait`, or a channel
round-trip executed per event, per row, or per keystroke. Each one is a
full thread handoff (µs-scale) plus potential QoS inversion.

**Fix.** Batch: cross the queue boundary once per burst, not once per item.
Or make the data immutable/snapshot-based so no crossing is needed on the
read path.

**Verify.** System Trace context-switch count drops; latency spans shrink.

---

## ObjC hot-loop overhead

**Detect.** Inside a per-row or per-frame loop: `objc_msgSend` dominating
Flow B samples, NSString ↔ UTF-8 bridging, NSArray boxing of primitives,
autorelease traffic (`objc_autorelease` in the profile), or per-iteration
small allocations (`malloc_zone_malloc` hot).

**Fix (in order of preference).**
1. Hoist loop-invariant ObjC calls; cache method results in locals.
2. Use C arrays / Zig slices across the FFI boundary and construct ObjC
   objects once at the edge (this repo's `MZAppRow` array is the model).
3. Wrap allocation-heavy loop bodies in `@autoreleasepool { }`.
4. For string-heavy paths, keep bytes as UTF-8 until display time.

**Verify.** `objc_msgSend`/`objc_autorelease` share of samples falls.

---

## SQLite checklist

Run through this whenever SQLite shows up in a profile — cheapest first:

1. **Prepared-statement reuse.** `sqlite3_prepare_v2` per call is a parser
   run per call; cache + `sqlite3_reset` (this repo: `Db.cachedStmt`).
2. **Transaction batching.** N inserts in one `BEGIN IMMEDIATE … COMMIT` is
   one fsync instead of N.
3. **WAL + synchronous=NORMAL** for local app data; `wal_autocheckpoint`
   sized so checkpoints don't stall the writer.
4. **Covering indexes.** `EXPLAIN QUERY PLAN` must not say SCAN for hot
   queries. `LIKE '%x%'` cannot use an index — acceptable at hundreds of
   rows, use FTS5 (with `unicode61` or trigram tokenizer for CJK substring
   match) when it isn't.
5. **Read only needed columns**; large blobs in their own table so row scans
   never page them in (this repo already splits `history_contents`).
6. **`sqlite3_bind_blob` with SQLITE_STATIC** (null destructor) when the
   buffer outlives the step — avoids SQLite's internal copy.
7. **mmap_size** set (64–256MB) so blob reads come from page cache without
   read() syscalls.

**Verify.** Time per operation via the repo bench; `EXPLAIN QUERY PLAN`
diff.

---

## Polling to event

**Detect.** A repeating timer checks for changes: pasteboard polling, file
stat loops, "did anything change?" queries. Flow E shows idle wakeups
proportional to the poll rate; battery cost with zero user-visible work.

**Fix.** Replace with the platform event source when one exists: FSEvents /
dispatch sources for files, kqueue for sockets/processes, NSNotification
observers for app state. **NSPasteboard has no change notification** — for
clipboard watchers, polling is the sanctioned mechanism; minimize its cost
instead: check only `changeCount` (one cheap call) per tick, keep the timer
tolerance ≥10% (coalesces wakeups), pause entirely while the popup that
would show results is closed if acceptable, and run at low QoS.

**Verify.** `powermetrics` idle-wakeups and energy for the process drop.

---

## Thundering herd (GCD)

**Detect.** A broadcast (`dispatch_group_notify` fan-out, condition
broadcast, or N `dispatch_async` wakeups) wakes every worker when only one
job exists; workers wake, find nothing, and re-sleep. Visible in System
Trace as short futile thread activations after each enqueue.

**Fix.** One job → one wakeup: a serial queue, or
`dispatch_source_merge_data` (coalescing counter semantics), or a
work-stealing structure where idle workers park individually.

**Verify.** Context switches per job approach 1; E-core residency rises.
