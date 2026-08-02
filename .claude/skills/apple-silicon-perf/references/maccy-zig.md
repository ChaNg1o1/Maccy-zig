# Maccy-zig hot paths and measurement harness

Project-specific companion to the flows and patterns. Update when hot paths
move.

## Architecture recap

Zig core (`main.zig`, `capture_service.zig`, `storage.zig`) + ObjC AppKit
shell (`macos_app.m`). All DB work runs on one serial GCD queue
(`mz_db_queue`); the UI thread receives row snapshots via
`mz_app_set_rows`. A 0.5s `NSTimer` (0.1s tolerance) drives pasteboard
polling, guarded by a semaphore so slow ticks don't pile up.

## Hot paths, in user-pain order

| Path | Code | Budget |
|------|------|--------|
| Popup open (hotkey → visible rows) | `mz_app_show` → `appRefreshRows` | < 100ms cold, < 33ms warm |
| Keystroke search | `appOnSearch` → `appRefreshRows` (LIKE query + full row rebuild + 3 dupeZ per row) | < 50ms at max_items=500 |
| Paste selection | `appWriteSelection` → blob read + pasteboard write + synthetic ⌘V | < 100ms for text |
| Poll tick (idle cost) | `pollTimer` → `captureClipboard`; no_change exits after one `changeCount` call | ~0 energy; E-core only |
| Capture (after real copy) | snapshot → SHA-256 → upsert txn | < 10ms text, < 100ms multi-MB image |
| Image preview | `mz_app_copy_image_preview` → full blob dup + NSImage decode | off main thread, cached |

## Measurement harness

```bash
# Build (always before measuring):
zig build -Doptimize=ReleaseFast

# Storage micro-bench (phases: sized inserts, bulk seed, refresh query, prune):
./zig-out/bin/maccy-zig bench --db /tmp/bench.sqlite --count 5000

# Wall-clock A/B of any CLI path:
hyperfine --warmup 3 './zig-out/bin/maccy-zig once --db /tmp/a.sqlite'

# Unit tests must stay green after every optimization:
zig build test

# GUI hotspots: launch app, then
sample maccy-zig 10 -file /tmp/sample.txt

# Idle energy of the running app:
sudo powermetrics --samplers tasks -i 1000 -n 5 | grep -i maccy
```

`bench` phase 3 times a close approximation of the UI refresh query (recency
scan + LIMIT, without the LIKE filter and pinned-rows union) — good enough
for index changes; measure real search latency in the GUI when the query
shape itself changes.

## Recorded baselines (Apple M5 Pro, 6P+12E, ReleaseFast, 2026-08)

| Metric | Value |
|--------|-------|
| Insert 1KB text | ~95µs |
| Insert 1MB blob (16KB pages) | ~810µs (was ~1210µs at 4KB pages) |
| Bulk seed per row | ~41µs |
| Refresh query, 500 rows | ~70–105µs |
| Steady-state prune (per insert) | ~160µs |
| Mass prune of 4500 rows | ~16ms |

## Known structural facts (verified against source)

- `appRefreshRows` runs per keystroke and rebuilds every row: one LIKE scan
  over `history_items`, then per-row `dupeZ` of title/app/subtitle into C
  strings, then `mz_app_set_rows` re-creates the row views. Patterns that
  apply: SQLite checklist (LIKE cannot use the index), ObjC hot-loop
  overhead (row view rebuild), dispatch_sync on hot path (search is
  debounced via `dispatchPendingSearch` — keep it that way).
- `captureClipboard` short-circuits on `changeCount` — the idle tick is one
  ObjC call + one integer compare. Poll-rate changes affect only energy,
  not correctness (dedup is hash-based).
- Capture path allocates a fresh C-string array of enabled types every tick
  that reaches snapshot; only after a real change, so cold-path.
- SHA-256 uses ARMv8 SHA2 hardware instructions via Zig std.crypto — not a
  bottleneck below ~100MB/s of clipboard traffic; do not replace with a
  weaker hash for speed.
- `writeItemToPasteboard` dups every blob through page_allocator before the
  pasteboard write; for multi-MB images this is one avoidable copy
  (SQLITE_STATIC + write before finalize, or read blob directly into the
  NSPasteboardItem buffer).
- Prune runs after every insert (`should_prune`) — a DELETE + subquery per
  copy. Fine at 500 rows; re-evaluate if max_items grows.

## Optimization etiquette for this repo

1. Never trade correctness invariants for speed: concealed-marker skip,
   persist-before-consume of change_count, pin preservation in prune.
2. Energy of the idle daemon outranks throughput of the capture path —
   a clipboard manager is judged on invisibility.
3. Verify with `zig build test` + the bench harness + (for UI claims) a
   sample trace of the real app. All three, every time.
