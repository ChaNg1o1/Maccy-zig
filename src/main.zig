const std = @import("std");
const capture_service = @import("capture_service.zig");
const storage = @import("storage.zig");
const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
    @cInclude("macos_app.h");
    @cInclude("macos_hotkey.h");
    @cInclude("macos_paste.h");
});

/// Unix epoch seconds (matches the value stored in `last_copied_at`).
fn nowUnix() i64 {
    return @intCast(c.time(null));
}

/// Monotonic timestamp in nanoseconds for benchmarking. Uses CLOCK_MONOTONIC so
/// it isn't perturbed by clock adjustments.
fn nowNs() i128 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i128, ts.tv_sec) * 1_000_000_000 + ts.tv_nsec;
}

const Config = struct {
    db_path: []const u8,
    interval_ms: u64 = 500,
    max_items: i64 = 500,
    max_items_overridden: bool = false,
    max_blob_bytes: usize = 16 * 1024 * 1024,
    /// 0 disables age-based pruning. Otherwise, unpinned items older than
    /// `max_age_days` (since last_copied_at) are deleted at startup and once
    /// per hour while the app runs. Pinned items are always preserved.
    max_age_days: i64 = 0,
    once: bool = false,
    import_source_path: ?[]const u8 = null,
    enabled_types: []const []const u8 = &default_types,
};

const default_types = [_][]const u8{
    "public.file-url",
    "public.html",
    "public.png",
    "public.rtf",
    "public.url",
    "public.url-name",
    "public.utf8-plain-text",
    "public.tiff",
    "public.jpeg",
    "public.heic",
};

const BlobView = storage.BlobView;
const Db = storage.Db;
const sqlite = storage.sqlite;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const default_db = try defaultDbPath(arena);

    var cfg = Config{ .db_path = default_db };
    if (args.len <= 1) {
        // GUI mode runs forever; arena would keep growing because every refresh
        // dupes ~600 strings and the arena can't actually free them. c_allocator
        // makes our explicit `allocator.free` calls real, so memory is bounded.
        try cmdApp(std.heap.c_allocator, cfg);
        return;
    }
    if (std.mem.eql(u8, args[1], "ocr-check")) {
        // Times the screen-reading fallback: model load, then per-capture cost.
        if (mz_ocr_self_check() != 0) return error.OcrCheckFailed;
        return;
    }
    if (std.mem.eql(u8, args[1], "ui-self-check")) {
        // Can every control in the app's windows be reached by a click?
        if (mz_app_ui_self_check() != 0) return error.UiSelfCheckFailed;
        return;
    }
    if (std.mem.eql(u8, args[1], "jev-context")) {
        // What Jev would be told about the focused field, after a short delay
        // to click into the app being asked about.
        if (mz_jev_print_context(3) != 0) return error.JevContextFailed;
        return;
    }
    if (std.mem.eql(u8, args[1], "jev-self-check")) {
        // Offline check of the Jev redaction / framing / confidence logic.
        // Declared here rather than via @cImport because macos_jev.h pulls in
        // Foundation, which translate-c cannot chew through.
        if (mz_jev_self_check() != 0) return error.JevSelfCheckFailed;
        return;
    }
    if (std.mem.eql(u8, args[1], "help") or std.mem.eql(u8, args[1], "--help")) {
        usage();
        return;
    }

    const cmd = args[1];
    try parseOptions(args[2..], &cfg);

    if (std.mem.eql(u8, cmd, "app")) {
        try cmdApp(std.heap.c_allocator, cfg);
    } else if (std.mem.eql(u8, cmd, "import-maccy")) {
        try cmdImportMaccy(arena, cfg);
    } else if (std.mem.eql(u8, cmd, "watch")) {
        // Long-running mode -- bounded heap, not the throwaway arena.
        try cmdWatch(std.heap.c_allocator, cfg);
    } else if (std.mem.eql(u8, cmd, "once")) {
        cfg.once = true;
        try cmdWatch(arena, cfg);
    } else if (std.mem.eql(u8, cmd, "stats")) {
        try cmdStats(cfg.db_path);
    } else if (std.mem.eql(u8, cmd, "list")) {
        try cmdList(cfg.db_path);
    } else if (std.mem.eql(u8, cmd, "jev-eval")) {
        try cmdJevEval(cfg.db_path, g_eval_limit);
    } else if (std.mem.eql(u8, cmd, "bench")) {
        try cmdBench(arena, cfg);
    } else {
        std.debug.print("unknown command: {s}\n\n", .{cmd});
        usage();
    }
}

extern fn mz_jev_self_check() c_int;
extern fn mz_jev_print_context(delay_seconds: c_int) c_int;

/// Mirrors MZJevEvalResult in macos_jev.h (not @cImport-able: it pulls in
/// Foundation).
const JevEvalResult = extern struct {
    choice_row: i64 = 0,
    accepted: c_int = 0,
    probability: f64 = 0,
    default_fits: f64 = -1,
    chosen_present: c_int = 0,
    input_tokens: c_int = 0,
};
extern fn mz_jev_eval_sample(sample_json: [*:0]const u8, chosen_row: i64, out: *JevEvalResult) c_int;

/// Most recent samples to replay. Each one is a billed request.
var g_eval_limit: usize = 50;

/// `maccy-zig jev-eval`: every paste made while Jev was on left behind the
/// question's ingredients and the answer the user gave by pasting. Replaying
/// them through the current request builder and acceptance rule turns "did
/// that change help?" from a feeling into a number.
fn cmdJevEval(db_path: []const u8, limit: usize) !void {
    var db = try Db.open(db_path);
    defer db.close();
    try db.migrate();

    // --- Free: how often is the newest entry what a panel-opener wants? ---
    const ranked = try evalFetchInt(&db, "SELECT COUNT(*) FROM paste_events WHERE row_rank >= 0;");
    std.debug.print("paste log: {d} paste(s) with a known list position\n", .{ranked});
    if (ranked > 0) {
        const top = try evalFetchInt(&db, "SELECT COUNT(*) FROM paste_events WHERE row_rank = 0;");
        const near = try evalFetchInt(&db, "SELECT COUNT(*) FROM paste_events WHERE row_rank BETWEEN 1 AND 2;");
        const deep = ranked - top - near;
        std.debug.print("  newest entry (row 0): {d:.0}%   rows 1-2: {d:.0}%   deeper: {d:.0}%\n", .{
            pct(top, ranked), pct(near, ranked), pct(deep, ranked),
        });
        std.debug.print("  (row 0 is what a suggestion has to beat: it is already selected for free)\n", .{});
    }

    const total = try evalFetchInt(&db, "SELECT COUNT(*) FROM jev_samples;");
    std.debug.print("\nsamples: {d} recorded", .{total});
    if (total == 0) {
        std.debug.print("\n  none yet -- they accumulate as you paste from the panel with Jev on.\n", .{});
        return;
    }
    std.debug.print(", replaying the latest {d} (one request each)\n\n", .{@min(limit, @as(usize, @intCast(total)))});

    const stmt = try db.prepare(
        \\SELECT id, dest_bundle_id, chosen_item_id, chosen_rank, suggested_item_id, sample_json
        \\FROM jev_samples ORDER BY id DESC LIMIT ?1;
    );
    defer _ = sqlite.sqlite3_finalize(stmt);
    _ = sqlite.sqlite3_bind_int64(stmt, 1, @intCast(limit));

    var replayed: i64 = 0;
    var present: i64 = 0;
    var top1: i64 = 0;
    var accepted: i64 = 0;
    var accepted_right: i64 = 0;
    var shown_live: i64 = 0;
    var ends_right: i64 = 0;
    var tokens: i64 = 0;
    var fits_when_default_sum: f64 = 0;
    var fits_when_default_n: i64 = 0;
    var fits_when_other_sum: f64 = 0;
    var fits_when_other_n: i64 = 0;

    while (try storage.stepRow(stmt)) {
        const sample_id = sqlite.sqlite3_column_int64(stmt, 0);
        const dest = sqlite.sqlite3_column_text(stmt, 1) orelse @as([*c]const u8, @ptrCast(""));
        const chosen = sqlite.sqlite3_column_int64(stmt, 2);
        const chosen_rank = sqlite.sqlite3_column_int(stmt, 3);
        const suggested = sqlite.sqlite3_column_int64(stmt, 4);
        const json = sqlite.sqlite3_column_text(stmt, 5) orelse continue;

        var result: JevEvalResult = .{};
        const rc = mz_jev_eval_sample(@ptrCast(json), chosen, &result);
        if (rc != 0) {
            const why = switch (rc) {
                3 => "no API key readable by this binary (run the one inside MaccyZig.app)",
                5 => "request failed",
                else => "unreadable sample",
            };
            std.debug.print("  #{d}: skipped, {s}\n", .{ sample_id, why });
            if (rc == 3) return;
            continue;
        }
        replayed += 1;
        tokens += result.input_tokens;
        if (suggested != 0) shown_live += 1;
        if (result.chosen_present != 0) present += 1;
        const right = result.choice_row == chosen;
        if (right and result.chosen_present != 0) top1 += 1;
        if (result.accepted != 0) {
            accepted += 1;
            if (right) accepted_right += 1;
        }
        if (result.default_fits >= 0) {
            if (chosen_rank == 0) {
                fits_when_default_sum += result.default_fits;
                fits_when_default_n += 1;
            } else {
                fits_when_other_sum += result.default_fits;
                fits_when_other_n += 1;
            }
        }
        // What the user experiences is the row the panel ends up on: a quiet
        // Jev leaves the newest entry selected, which is right whenever the
        // newest entry is what they pasted.
        const lands_right = if (result.accepted != 0) right else chosen_rank == 0;
        if (lands_right) ends_right += 1;
        const verdict: []const u8 = if (result.accepted != 0)
            (if (!right) "moved, WRONG" else if (chosen_rank == 0) "confirmed default, RIGHT" else "moved, RIGHT")
        else
            (if (chosen_rank == 0) "quiet, default was right" else "quiet, missed");
        // Unsigned for display: Zig prints an explicit '+' on padded signed ints.
        std.debug.print("  #{d:<5} {s:<28} pasted row {d} (rank {d})  jev row {d} p={d:.2}  {s}\n", .{
            @as(u64, @intCast(sample_id)), std.mem.span(dest), chosen, chosen_rank, result.choice_row, result.probability, verdict,
        });
    }
    if (replayed == 0) return;

    std.debug.print("\nsummary over {d} replayed sample(s)\n", .{replayed});
    std.debug.print("  panel ends on the row that was pasted   {d}/{d}  ({d:.0}%)   <- the number that matters\n", .{ ends_right, replayed, pct(ends_right, replayed) });
    std.debug.print("  wanted entry was among the candidates   {d}/{d}\n", .{ present, replayed });
    std.debug.print("  Jev's first choice = what was pasted    {d}/{d}  ({d:.0}%)\n", .{ top1, present, pct(top1, present) });
    std.debug.print("  suggestions that pass the accept rule   {d}/{d}  ({d:.0}% coverage)\n", .{ accepted, replayed, pct(accepted, replayed) });
    std.debug.print("  ...of which right                       {d}/{d}  ({d:.0}% precision)\n", .{ accepted_right, accepted, pct(accepted_right, accepted) });
    std.debug.print("  ...of which WRONG (selection yanked)    {d}\n", .{accepted - accepted_right});
    if (fits_when_default_n > 0 or fits_when_other_n > 0) {
        std.debug.print("  shadow default_fits: mean {d:.2} when row 0 was pasted (n={d}), {d:.2} when another row was (n={d})\n", .{
            mean(fits_when_default_sum, fits_when_default_n), fits_when_default_n,
            mean(fits_when_other_sum, fits_when_other_n),     fits_when_other_n,
        });
        std.debug.print("    (worth wiring in as a brake only if these two numbers sit clearly apart)\n", .{});
    }
    std.debug.print("  a live suggestion was on screen for {d}/{d}: agreement there is inflated by anchoring\n", .{ shown_live, replayed });
    std.debug.print("  input tokens per request: {d}\n", .{@divTrunc(tokens, replayed)});
}

fn evalFetchInt(db: *Db, sql: [:0]const u8) !i64 {
    const stmt = try db.prepare(sql);
    defer _ = sqlite.sqlite3_finalize(stmt);
    if (!(try storage.stepRow(stmt))) return 0;
    return sqlite.sqlite3_column_int64(stmt, 0);
}

fn pct(part: i64, whole: i64) f64 {
    if (whole <= 0) return 0;
    return @as(f64, @floatFromInt(part)) * 100.0 / @as(f64, @floatFromInt(whole));
}

fn mean(sum: f64, n: i64) f64 {
    if (n <= 0) return 0;
    return sum / @as(f64, @floatFromInt(n));
}
extern fn mz_ocr_self_check() c_int;
extern fn mz_app_ui_self_check() c_int;

fn usage() void {
    std.debug.print(
        \\maccy-zig: Zig-native high-performance Maccy core prototype
        \\
        \\Commands:
        \\  once                 Capture current pasteboard once and persist it
        \\  watch                Poll pasteboard and persist changed copies
        \\  list                 Show recent stored history rows
        \\  stats                Show SQLite/blob size profile
        \\  bench                Insert synthetic fixture rows for storage profiling
        \\  jev-self-check       Offline check of the Jev suggestion logic
        \\  ui-self-check        Check that every control in the app's windows can be clicked
        \\  ocr-check            Time the screen-reading fallback used by Jev
        \\  jev-eval             Replay recorded pastes against Jev and score it (--limit N)
        \\  jev-context          Show what Jev is told about the focused field (3 s delay)
        \\
        \\Options:
        \\  --db PATH            SQLite path (default: ~/Library/Application Support/MaccyZig/Storage.sqlite)
        \\  --interval-ms N      Poll interval for watch (default: 500)
        \\  --max-items N        Unpinned history cap (default: 500)
        \\  --max-blob-mib N     Skip individual pasteboard blobs above N MiB (default: 16)
        \\  --max-age-days N     Auto-delete unpinned items older than N days (default: 0 = off)
        \\  --no-images          Store text/html/rtf/file URLs only
        \\
        \\Examples:
        \\  zig build run -- once
        \\  zig build -Doptimize=ReleaseFast
        \\  ./zig-out/bin/maccy-zig watch --max-blob-mib 4
        \\
    , .{});
}

fn parseOptions(args: []const []const u8, cfg: *Config) !void {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--db")) {
            i += 1;
            if (i >= args.len) return error.MissingDbPath;
            cfg.db_path = args[i];
        } else if (std.mem.eql(u8, arg, "--interval-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingInterval;
            cfg.interval_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--max-items")) {
            i += 1;
            if (i >= args.len) return error.MissingMaxItems;
            cfg.max_items = try std.fmt.parseInt(i64, args[i], 10);
            cfg.max_items_overridden = true;
        } else if (std.mem.eql(u8, arg, "--max-blob-mib")) {
            i += 1;
            if (i >= args.len) return error.MissingMaxBlob;
            const mib = try std.fmt.parseInt(usize, args[i], 10);
            cfg.max_blob_bytes = mib * 1024 * 1024;
        } else if (std.mem.eql(u8, arg, "--max-age-days")) {
            i += 1;
            if (i >= args.len) return error.MissingMaxAgeDays;
            cfg.max_age_days = try std.fmt.parseInt(i64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--count")) {
            i += 1;
            if (i >= args.len) return error.MissingBenchCount;
            g_bench_count = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--limit")) {
            i += 1;
            if (i >= args.len) return error.MissingEvalLimit;
            g_eval_limit = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--no-images")) {
            cfg.enabled_types = &[_][]const u8{
                "public.file-url",
                "public.html",
                "public.rtf",
                "public.url",
                "public.url-name",
                "public.utf8-plain-text",
            };
        } else if (std.mem.eql(u8, arg, "--source")) {
            i += 1;
            if (i >= args.len) return error.MissingSourcePath;
            cfg.import_source_path = args[i];
        } else {
            return error.UnknownOption;
        }
    }
}

fn defaultDbPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = if (c.getenv("HOME")) |home_c| std.mem.span(home_c) else ".";
    return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "MaccyZig", "Storage.sqlite" });
}

fn ensureParent(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    if (dir.len == 0) return;

    var i: usize = if (dir[0] == '/') 1 else 0;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or dir[i] == '/') {
            if (i == 0) continue;
            const part = dir[0..i];
            const z = try std.heap.page_allocator.dupeZ(u8, part);
            defer std.heap.page_allocator.free(z);
            _ = c.mkdir(z.ptr, 0o755);
        }
    }
}

fn cmdWatch(allocator: std.mem.Allocator, cfg: Config) !void {
    try ensureParent(cfg.db_path);
    var db = try Db.open(cfg.db_path);
    defer db.close();
    try db.migrate();
    _ = try db.prune(cfg.max_items);
    if (cfg.max_age_days > 0) {
        const removed = try maybePruneByAge(&db, cfg.max_age_days);
        if (removed > 0) {
            std.debug.print(
                "startup ttl prune removed={d} max_age_days={d}\n",
                .{ removed, cfg.max_age_days },
            );
        }
    }
    var last_age_sweep = nowUnix();

    var last_change: i64 = -1;
    while (true) {
        // A transient failure (pasteboard churn, SQLITE_BUSY from another
        // process) must not kill the long-running watcher.
        const result = capture_service.captureClipboard(allocator, &db, .{
            .enabled_types = cfg.enabled_types,
            .max_blob_bytes = cfg.max_blob_bytes,
        }, &last_change) catch |err| {
            std.debug.print("capture failed: {s} (retrying)\n", .{@errorName(err)});
            if (cfg.once) return err;
            _ = c.usleep(@intCast(cfg.interval_ms * 1000));
            continue;
        };
        if (result.should_prune) {
            _ = try db.prune(cfg.max_items);
        }
        if (cfg.max_age_days > 0) {
            const now = nowUnix();
            if (now - last_age_sweep >= AGE_PRUNE_INTERVAL_SECONDS) {
                last_age_sweep = now;
                _ = maybePruneByAge(&db, cfg.max_age_days) catch |err| blk: {
                    std.debug.print("ttl prune failed: {s}\n", .{@errorName(err)});
                    break :blk @as(i64, 0);
                };
            }
        }
        switch (result.disposition) {
            .inserted => std.debug.print(
                "captured change={} blobs={} skipped={}/{}/{} db={s}\n",
                .{
                    result.change_count,
                    result.blob_count,
                    result.skipped_type_count,
                    result.skipped_oversize_count,
                    result.skipped_transient_count,
                    cfg.db_path,
                },
            ),
            .duplicate_reordered => std.debug.print(
                "reordered change={} blobs={} skipped={}/{}/{} db={s}\n",
                .{
                    result.change_count,
                    result.blob_count,
                    result.skipped_type_count,
                    result.skipped_oversize_count,
                    result.skipped_transient_count,
                    cfg.db_path,
                },
            ),
            .skipped_self_generated, .skipped_concealed, .skipped_empty, .no_change => {},
        }

        if (cfg.once) break;
        _ = c.usleep(@intCast(cfg.interval_ms * 1000));
    }
}

fn cmdStats(db_path: []const u8) !void {
    var db = try Db.open(db_path);
    defer db.close();
    try db.migrate();
    try printRows(db.handle,
        \\SELECT type,
        \\       COUNT(*) AS rows,
        \\       ROUND(SUM(LENGTH(value))/1048576.0, 2) AS mib,
        \\       ROUND(MAX(LENGTH(value))/1048576.0, 2) AS max_mib
        \\FROM history_contents GROUP BY type ORDER BY SUM(LENGTH(value)) DESC;
    );
}

fn cmdList(db_path: []const u8) !void {
    var db = try Db.open(db_path);
    defer db.close();
    try db.migrate();
    try printRows(db.handle,
        \\SELECT id, datetime(last_copied_at, 'unixepoch', 'localtime') AS copied,
        \\       copy_count, substr(title, 1, 80) AS title
        \\FROM history_items ORDER BY last_copied_at DESC LIMIT 30;
    );
}

fn printRows(handle: *sqlite.sqlite3, sql: [:0]const u8) !void {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(handle, sql.ptr, -1, &stmt, null) != sqlite.SQLITE_OK) return error.SqlitePrepareFailed;
    defer _ = sqlite.sqlite3_finalize(stmt.?);
    var stderr_buffer: [4096]u8 = undefined;
    const stderr = std.debug.lockStderr(&stderr_buffer);
    defer std.debug.unlockStderr();
    const writer = &stderr.file_writer.interface;
    const cols = sqlite.sqlite3_column_count(stmt.?);
    while (sqlite.sqlite3_step(stmt.?) == sqlite.SQLITE_ROW) {
        var i: c_int = 0;
        while (i < cols) : (i += 1) {
            const name = sqlite.sqlite3_column_name(stmt.?, i);
            const txt = sqlite.sqlite3_column_text(stmt.?, i);
            try writer.print("{s}=", .{std.mem.span(name)});
            if (txt != null) {
                try writer.print("{s}", .{std.mem.span(txt)});
            } else {
                try writer.writeAll("NULL");
            }
            if (i + 1 < cols) try writer.writeByte('\t');
        }
        try writer.writeByte('\n');
    }
    try writer.flush();
}

fn cmdBench(allocator: std.mem.Allocator, cfg: Config) !void {
    try ensureParent(cfg.db_path);
    var db = try Db.open(cfg.db_path);
    defer db.close();
    try db.migrate();

    // Phase 1: representative single-shot inserts at four payload sizes; useful for
    // tracking per-row cost across blob size buckets.
    const phase_start = nowNs();
    const sizes = [_]usize{ 64, 1024, 64 * 1024, 1024 * 1024 };
    for (sizes) |size| {
        const data = try allocator.alloc(u8, size);
        defer allocator.free(data);
        @memset(data, @as(u8, @intCast(size & 0xff)));
        const blob = [_]BlobView{.{ .ty = "public.utf8-plain-text", .data = data }};
        const t0 = nowNs();
        const hash = capture_service.computeHashHex(&blob);
        var title: [256]u8 = [_]u8{0} ** 256;
        const label = try std.fmt.bufPrint(title[0..], "bench {d} bytes", .{size});
        if (label.len < title.len) title[label.len] = 0;
        _ = try db.upsertCapture(&blob, &hash, &title, "bench", .text);
        std.debug.print(
            "  size={d:>8} insert_us={d:>10}\n",
            .{ size, @divTrunc(nowNs() - t0, 1000) },
        );
    }
    std.debug.print("phase1_total_us={d}\n", .{@divTrunc(nowNs() - phase_start, 1000)});

    // Phase 2: optional bulk seed for stress testing the list/search path. Each row
    // gets a unique title so titleFromBlobs / hash-based dedup don't collapse them.
    if (g_bench_count > 0) {
        std.debug.print("phase2: seeding {d} synthetic rows...\n", .{g_bench_count});
        var seeded: usize = 0;
        const seed_start = nowNs();
        // Cheap pseudo-random salt mixed from the pid so repeated bench runs don't
        // collide on identical hashes; doesn't need cryptographic quality.
        const salt: u64 = @as(u64, @intCast(@as(c_uint, @bitCast(c.getpid())))) ^ @as(u64, @intCast(seed_start & 0xffff_ffff));
        var i: usize = 0;
        while (i < g_bench_count) : (i += 1) {
            var payload: [256]u8 = undefined;
            const text = try std.fmt.bufPrint(payload[0..], "stress-row-{x}-{d}", .{ salt ^ i, i });
            const blob = [_]BlobView{.{ .ty = "public.utf8-plain-text", .data = text }};
            const hash = capture_service.computeHashHex(&blob);
            var title: [256]u8 = [_]u8{0} ** 256;
            @memcpy(title[0..text.len], text);
            switch (try db.upsertCapture(&blob, &hash, &title, "bench", .text)) {
                .inserted => seeded += 1,
                .duplicate => {},
            }
        }
        const elapsed_ns = nowNs() - seed_start;
        const ms = @divTrunc(elapsed_ns, 1_000_000);
        const per_us: i128 = if (g_bench_count > 0) @divTrunc(elapsed_ns, 1000 * @as(i128, @intCast(g_bench_count))) else 0;
        std.debug.print(
            "phase2_total_ms={d} per_row_us={d} seeded={d}\n",
            .{ ms, per_us, seeded },
        );
    }

    // Phase 3: time the actual UI refresh query against whatever's now in the DB.
    {
        const refresh_start = nowNs();
        const sql =
            \\SELECT id, title, COALESCE(app, ''), copy_count, last_copied_at
            \\FROM history_items
            \\ORDER BY last_copied_at DESC, id DESC
            \\LIMIT ?1;
        ;
        const stmt = try db.prepare(sql);
        defer _ = sqlite.sqlite3_finalize(stmt);
        _ = sqlite.sqlite3_bind_int64(stmt, 1, cfg.max_items);
        var rows: usize = 0;
        while (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) rows += 1;
        std.debug.print(
            "phase3_refresh_us={d} rows={d}\n",
            .{ @divTrunc(nowNs() - refresh_start, 1000), rows },
        );
    }

    // Phase 4: prune cost with whatever sits above max_items.
    {
        const prune_start = nowNs();
        const removed = try db.prune(cfg.max_items);
        std.debug.print(
            "phase4_prune_us={d} removed={d}\n",
            .{ @divTrunc(nowNs() - prune_start, 1000), removed },
        );
    }

    // Phase 5: TTL prune cost if requested.
    if (cfg.max_age_days > 0) {
        const ttl_start = nowNs();
        const removed = try maybePruneByAge(&db, cfg.max_age_days);
        std.debug.print(
            "phase5_ttl_us={d} removed={d} max_age_days={d}\n",
            .{ @divTrunc(nowNs() - ttl_start, 1000), removed, cfg.max_age_days },
        );
    }

    // Final row count for context.
    var row_total: i64 = 0;
    {
        const stmt = try db.prepare("SELECT COUNT(*) FROM history_items;");
        defer _ = sqlite.sqlite3_finalize(stmt);
        if (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            row_total = sqlite.sqlite3_column_int64(stmt, 0);
        }
    }
    std.debug.print("bench complete db={s} total_rows={d}\n", .{ cfg.db_path, row_total });
}

test "escapeLikeQuery escapes wildcards and backslashes" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("100\\%", escapeLikeQuery("100%", &buf));
    try std.testing.expectEqualStrings("a\\_b", escapeLikeQuery("a_b", &buf));
    try std.testing.expectEqualStrings("c:\\\\dir", escapeLikeQuery("c:\\dir", &buf));
    try std.testing.expectEqualStrings("plain", escapeLikeQuery("plain", &buf));
}

test "hash changes with content" {
    const a = [_]BlobView{.{ .ty = "public.utf8-plain-text", .data = "a" }};
    const b = [_]BlobView{.{ .ty = "public.utf8-plain-text", .data = "b" }};
    try std.testing.expect(!std.mem.eql(u8, &capture_service.computeHashHex(&a), &capture_service.computeHashHex(&b)));
}

test "fuzz title sanitizer removes control separators" {
    try std.testing.fuzz({}, fuzzTitleSanitizer, .{});
}

fn fuzzTitleSanitizer(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    var buf: [256]u8 = undefined;
    const len = smith.valueRangeAtMost(u16, 0, buf.len);
    const slice = buf[0..len];
    smith.bytes(slice);
    capture_service.sanitizeTitle(slice);
    for (slice) |b| {
        try std.testing.expect(b != 0);
        try std.testing.expect(b != '\n');
        try std.testing.expect(b != '\t');
    }
}

var g_app_db: ?*Db = null;
var g_app_allocator: ?std.mem.Allocator = null;
var g_app_query: [256]u8 = [_]u8{0} ** 256;
var g_app_query_len: usize = 0;
var g_app_last_change: i64 = -1;
var g_app_max_items: i64 = 500;
var g_app_max_blob_bytes: usize = 16 * 1024 * 1024;
var g_app_max_age_days: i64 = 0;
var g_app_last_age_prune_unix: i64 = 0;
var g_app_enabled_types: []const []const u8 = &default_types;
var g_refresh_stmt: ?*sqlite.sqlite3_stmt = null;
var g_bench_count: usize = 0;

const AGE_PRUNE_INTERVAL_SECONDS: i64 = 3600; // run TTL sweep at most once per hour
const SECONDS_PER_DAY: i64 = 86400;

fn maybePruneByAge(db: *Db, max_age_days: i64) !i64 {
    if (max_age_days <= 0) return 0;
    const now = nowUnix();
    const cutoff = now - max_age_days * SECONDS_PER_DAY;
    return try db.pruneOlderThan(cutoff);
}

/// Open + migrate for the GUI. A corrupt Storage.sqlite must not make the app
/// silently fail to launch (there is no terminal to read the error from), so
/// the damaged file is quarantined and a fresh database is started instead.
fn openAppDb(path: []const u8) !Db {
    if (Db.open(path)) |opened| {
        var db = opened;
        if (db.migrate()) {
            return db;
        } else |err| {
            std.debug.print("migrate failed: {s}; quarantining database\n", .{@errorName(err)});
            db.close();
        }
    } else |err| {
        std.debug.print("open failed: {s}; quarantining database\n", .{@errorName(err)});
    }
    quarantineCorruptDb(path);
    var db = try Db.open(path);
    try db.migrate();
    return db;
}

fn quarantineCorruptDb(path: []const u8) void {
    var buf: [1024]u8 = undefined;
    const suffixes = [_][]const u8{ "", "-wal", "-shm" };
    for (suffixes) |suffix| {
        const src = std.fmt.bufPrintZ(buf[0..512], "{s}{s}", .{ path, suffix }) catch continue;
        const dst = std.fmt.bufPrintZ(buf[512..], "{s}{s}.corrupt", .{ path, suffix }) catch continue;
        _ = c.rename(src.ptr, dst.ptr);
    }
}

fn cmdApp(allocator: std.mem.Allocator, cfg: Config) !void {
    var effective_cfg = cfg;
    if (!effective_cfg.max_items_overridden) {
        effective_cfg.max_items = c.mz_app_load_max_items(effective_cfg.max_items);
    }
    c.mz_app_set_initial_max_items(effective_cfg.max_items);

    try ensureParent(effective_cfg.db_path);
    var db = try openAppDb(effective_cfg.db_path);
    defer db.close();

    // Bring storage in line with retention policy *before* the UI loads its first
    // snapshot, so cold-start visible rows already reflect any TTL/cap trimming.
    _ = try db.prune(effective_cfg.max_items);
    if (effective_cfg.max_age_days > 0) {
        const removed = try maybePruneByAge(&db, effective_cfg.max_age_days);
        if (removed > 0) {
            std.debug.print(
                "startup ttl prune removed={d} max_age_days={d}\n",
                .{ removed, effective_cfg.max_age_days },
            );
        }
    }
    g_app_last_age_prune_unix = nowUnix();

    g_app_db = &db;
    g_app_allocator = allocator;
    g_app_max_items = effective_cfg.max_items;
    g_app_max_blob_bytes = effective_cfg.max_blob_bytes;
    g_app_max_age_days = effective_cfg.max_age_days;
    g_app_enabled_types = effective_cfg.enabled_types;

    const callbacks = c.MZAppCallbacks{
        .on_toggle = appOnToggle,
        .on_poll = appOnPoll,
        .on_search = appOnSearch,
        .on_select = appOnSelect,
        .on_clear = appOnClear,
        .on_quit = appOnQuit,
        .on_max_items_change = appOnMaxItemsChange,
    };
    c.mz_app_set_action_callback(appOnAction);
    const hotkey_status = c.mz_hotkey_register_popup(appOnHotkey);
    if (hotkey_status != 0) {
        std.debug.print("failed to register popup hotkey status={d}\n", .{hotkey_status});
    }
    defer c.mz_hotkey_unregister_popup();
    try appRefreshRows();
    c.mz_app_run(callbacks);
}

fn appOnHotkey() callconv(.c) void {
    c.mz_app_show();
}

fn appOnToggle() callconv(.c) void {
    appRefreshRows() catch |err| {
        std.debug.print("appRefreshRows (toggle) failed: {s}\n", .{@errorName(err)});
    };
}

fn appOnPoll() callconv(.c) void {
    appPollClipboard() catch |err| {
        std.debug.print("appPollClipboard failed: {s}\n", .{@errorName(err)});
    };
}

fn appOnSearch(query: [*c]const u8) callconv(.c) void {
    const q = if (query != null) std.mem.span(query) else "";
    var n = @min(q.len, g_app_query.len);
    // Never cut a multi-byte character in half at the cap — SQLite LIKE on
    // invalid UTF-8 misbehaves.
    while (n > 0 and !std.unicode.utf8ValidateSlice(q[0..n])) : (n -= 1) {}
    @memset(&g_app_query, 0);
    @memcpy(g_app_query[0..n], q[0..n]);
    g_app_query_len = n;
    appRefreshRows() catch |err| {
        std.debug.print("appRefreshRows (search) failed: {s}\n", .{@errorName(err)});
    };
}

fn appOnSelect(id: i64, paste: c_int, target_pid: c_int) callconv(.c) void {
    appWriteSelection(id, false, paste != 0, target_pid) catch return;
}

fn appOnMaxItemsChange(max_items: i64) callconv(.c) void {
    if (max_items <= 0) return;
    g_app_max_items = max_items;
    if (g_app_db) |db| {
        const removed = db.prune(max_items) catch |err| {
            std.debug.print("prune after max-items change failed: {s}\n", .{@errorName(err)});
            return;
        };
        if (removed > 0) c.mz_app_invalidate_preview_cache();
        appRefreshRows() catch |err| {
            std.debug.print("appRefreshRows (max-items) failed: {s}\n", .{@errorName(err)});
        };
    }
}

fn appOnAction(action: c.MZAppAction, row_id: i64, target_pid: c_int) callconv(.c) void {
    if (g_app_db) |db| {
        switch (action) {
            c.MZ_APP_ACTION_COPY => appWriteSelection(row_id, false, false, 0) catch return,
            c.MZ_APP_ACTION_PASTE => appWriteSelection(row_id, false, true, target_pid) catch return,
            c.MZ_APP_ACTION_PASTE_PLAIN => appWriteSelection(row_id, true, true, target_pid) catch return,
            c.MZ_APP_ACTION_REVEAL => appRevealSelection(row_id) catch return,
            c.MZ_APP_ACTION_TOGGLE_PIN => {
                _ = db.togglePin(row_id) catch return;
                appRefreshRows() catch {};
            },
            c.MZ_APP_ACTION_CLEAR_UNPINNED => {
                db.clearUnpinned() catch return;
                // SQLite reuses INTEGER PRIMARY KEY values, so any cached image
                // preview keyed on rowID could now belong to a future row.
                c.mz_app_invalidate_preview_cache();
                appRefreshRows() catch {};
            },
            c.MZ_APP_ACTION_CLEAR_ALL => {
                db.clearAll() catch return;
                c.mz_app_invalidate_preview_cache();
                appRefreshRows() catch {};
            },
            c.MZ_APP_ACTION_QUIT => std.process.exit(0),
            else => {},
        }
    }
}

fn appOnClear(all: c_int) callconv(.c) void {
    if (g_app_db) |db| {
        if (all != 0) db.clearAll() catch {} else db.clearUnpinned() catch {};
        c.mz_app_invalidate_preview_cache();
        appRefreshRows() catch {};
    }
}

fn appOnQuit() callconv(.c) void {}

fn appPollClipboard() !void {
    const db = g_app_db orelse return;
    const allocator = g_app_allocator orelse std.heap.page_allocator;
    const result = try capture_service.captureClipboard(allocator, db, .{
        .enabled_types = g_app_enabled_types,
        .max_blob_bytes = g_app_max_blob_bytes,
    }, &g_app_last_change);
    if (result.should_prune) {
        // No preview-cache invalidation here: the capacity cull removes old
        // rows while the just-inserted row keeps the max rowid alive, so
        // SQLite cannot hand a deleted id to a future insert.
        _ = try db.prune(g_app_max_items);
    }

    // Run TTL-based pruning at most once per AGE_PRUNE_INTERVAL_SECONDS so a long-running
    // session eventually evicts items that crossed the age boundary while idle.
    if (g_app_max_age_days > 0) {
        const now = nowUnix();
        if (now - g_app_last_age_prune_unix >= AGE_PRUNE_INTERVAL_SECONDS) {
            g_app_last_age_prune_unix = now;
            const removed = maybePruneByAge(db, g_app_max_age_days) catch |err| blk: {
                std.debug.print("ttl prune failed: {s}\n", .{@errorName(err)});
                break :blk 0;
            };
            // Same rowid-reuse reasoning as the capacity prune above: age-based
            // deletes only remove old rows, so cached previews stay valid.
            if (removed > 0) {
                try appRefreshRows();
            }
        }
    }

    if (result.should_refresh_rows) {
        try appRefreshRows();
    }
}

fn appWriteSelection(id: i64, plain_only: bool, paste_after: bool, target_pid: c_int) !void {
    const db = g_app_db orelse return;
    db.writeItemToPasteboard(id, plain_only) catch |err| {
        // The row may have been pruned since the UI snapshot, or "paste as
        // plain text" hit an image-only item. The panel is already hidden at
        // this point, so at least make the failure audible.
        std.debug.print("writeItemToPasteboard failed: {s}\n", .{@errorName(err)});
        c.mz_app_beep();
        return err;
    };
    const ax_trusted = c.mz_ax_is_trusted(0) != 0;
    std.debug.print(
        "appWriteSelection rowID={d} plain={any} paste_after={any} ax_trusted={any} target_pid={d}\n",
        .{ id, plain_only, paste_after, ax_trusted, target_pid },
    );
    if (paste_after) {
        if (!ax_trusted) {
            // The native AXIsProcessTrustedWithOptions prompt is too easy to
            // miss, so route through our app-level alert which activates the
            // app and jumps directly to System Settings → Accessibility on
            // confirm. We also keep the terminal warning so debug runs still
            // surface the cause if the alert is dismissed.
            std.debug.print(
                "  ⚠️  ⌘V NOT posted: Accessibility permission missing. " ++
                    "Showing in-app prompt; the user must enable MaccyZig under " ++
                    "Privacy & Security → Accessibility before paste will work.\n",
                .{},
            );
            c.mz_app_show_accessibility_alert();
            return;
        }
        c.mz_post_command_v_to_pid(target_pid);
    }
}

fn appRevealSelection(id: i64) !void {
    const db = g_app_db orelse return;
    const allocator = g_app_allocator orelse std.heap.page_allocator;
    const target = try db.readRevealTarget(id, allocator) orelse return;
    defer allocator.free(target);

    const target_z = try allocator.dupeZ(u8, target);
    defer allocator.free(target_z);
    c.mz_app_reveal_target(target_z.ptr);
}

fn escapeLikeQuery(query: []const u8, buf: []u8) []const u8 {
    var out: usize = 0;
    for (query) |b| {
        if (b == '%' or b == '_' or b == '\\') {
            buf[out] = '\\';
            out += 1;
        }
        buf[out] = b;
        out += 1;
    }
    return buf[0..out];
}

fn appRefreshRows() !void {
    const db = g_app_db orelse return;
    const allocator = g_app_allocator orelse std.heap.page_allocator;
    var rows = std.ArrayList(c.MZAppRow).empty;
    defer rows.deinit(allocator);
    var strings = std.ArrayList([:0]u8).empty;
    defer {
        for (strings.items) |value| allocator.free(value);
        strings.deinit(allocator);
    }

    // Escape LIKE wildcards so searching for "100%" or "a_b" matches
    // literally. Worst case doubles the query length.
    var escaped_buf: [2 * g_app_query.len]u8 = undefined;
    const query = escapeLikeQuery(g_app_query[0..g_app_query_len], &escaped_buf);
    const stmt = g_refresh_stmt orelse blk: {
        // The row cap applies to unpinned rows only: pinned items must stay
        // visible forever, but a plain LIMIT on recency order would push old
        // favorites out of the window as new copies arrive.
        const sql =
            \\SELECT id,
            \\       title,
            \\       COALESCE(app, ''),
            \\       CASE
            \\         WHEN content_kind=?2 THEN 'Copied as Image'
            \\         WHEN content_kind=?3 THEN 'Copied as File'
            \\         WHEN COALESCE(app, '') <> '' THEN app
            \\         WHEN content_kind=?4 THEN 'Copied as Link'
            \\         WHEN content_kind=?5 THEN 'Copied as Plain Text'
            \\         ELSE 'Copied Data'
            \\       END AS subtitle,
            \\       pin IS NOT NULL AS is_pinned,
            \\       copy_count,
            \\       last_copied_at,
            \\       COALESCE(pin_order, 0) AS pin_order,
            \\       content_kind=?2 AS has_image,
            \\       content_kind,
            \\       COALESCE(source_context, '')
            \\FROM history_items
            \\WHERE (?1 = '' OR title LIKE '%' || ?1 || '%' ESCAPE '\' OR app LIKE '%' || ?1 || '%' ESCAPE '\')
            \\  AND (pin IS NOT NULL OR id IN (
            \\        SELECT id FROM history_items WHERE pin IS NULL
            \\        ORDER BY last_copied_at DESC, id DESC LIMIT ?6))
            \\ORDER BY last_copied_at DESC, id DESC;
        ;
        const prepared = try db.prepare(sql);
        // bind kind constants once; they never change between refreshes
        _ = sqlite.sqlite3_bind_int(prepared, 2, c.MZ_APP_CONTENT_IMAGE);
        _ = sqlite.sqlite3_bind_int(prepared, 3, c.MZ_APP_CONTENT_FILE);
        _ = sqlite.sqlite3_bind_int(prepared, 4, c.MZ_APP_CONTENT_LINK);
        _ = sqlite.sqlite3_bind_int(prepared, 5, c.MZ_APP_CONTENT_TEXT);
        g_refresh_stmt = prepared;
        break :blk prepared;
    };
    _ = sqlite.sqlite3_reset(stmt);
    try storage.bindText(stmt, 1, query);
    _ = sqlite.sqlite3_bind_int64(stmt, 6, g_app_max_items);
    while (try storage.stepRow(stmt)) {
        const title_txt = sqlite.sqlite3_column_text(stmt, 1) orelse @as([*c]const u8, @ptrCast(""));
        const app_txt = sqlite.sqlite3_column_text(stmt, 2) orelse @as([*c]const u8, @ptrCast(""));
        const subtitle_txt = sqlite.sqlite3_column_text(stmt, 3) orelse @as([*c]const u8, @ptrCast(""));
        const source_txt = sqlite.sqlite3_column_text(stmt, 10) orelse @as([*c]const u8, @ptrCast(""));
        const title_z = try allocator.dupeZ(u8, std.mem.span(title_txt));
        const app_z = try allocator.dupeZ(u8, std.mem.span(app_txt));
        const subtitle_z = try allocator.dupeZ(u8, std.mem.span(subtitle_txt));
        const source_z = try allocator.dupeZ(u8, std.mem.span(source_txt));
        try strings.append(allocator, title_z);
        try strings.append(allocator, app_z);
        try strings.append(allocator, subtitle_z);
        try strings.append(allocator, source_z);
        try rows.append(allocator, .{
            .id = sqlite.sqlite3_column_int64(stmt, 0),
            .title = title_z.ptr,
            .subtitle = subtitle_z.ptr,
            .app = app_z.ptr,
            .copied_at = sqlite.sqlite3_column_int64(stmt, 6),
            .pin_order = sqlite.sqlite3_column_int64(stmt, 7),
            .content_kind = sqlite.sqlite3_column_int(stmt, 9),
            .pinned = sqlite.sqlite3_column_int(stmt, 4),
            .has_image = sqlite.sqlite3_column_int(stmt, 8),
            .copy_count = sqlite.sqlite3_column_int(stmt, 5),
            .source_context = source_z.ptr,
        });
    }
    c.mz_app_set_rows(rows.items.ptr, rows.items.len);
    c.mz_app_set_status_text("M");
}

pub export fn mz_app_copy_image_preview(row_id: i64, len_out: ?*usize) ?[*]const u8 {
    if (len_out) |len| len.* = 0;
    const db = g_app_db orelse return null;
    const preview = db.readImagePreview(row_id, std.heap.c_allocator) catch return null;
    const bytes = preview orelse return null;
    if (len_out) |len| len.* = bytes.len;
    return bytes.ptr;
}

/// Log a paste so the Jev suggestion has a memory of what this user actually
/// does in this app. Called from the panel, which is the only place that knows
/// which app the paste is going to. When `sample_json` is present the paste is
/// also kept as an evaluation sample: the question's ingredients plus the
/// answer the user gave by pasting.
pub export fn mz_app_record_paste(
    row_id: i64,
    dest_bundle_id: ?[*:0]const u8,
    was_suggested: c_int,
    row_rank: c_int,
    suggested_row_id: i64,
    sample_json: ?[*:0]const u8,
) void {
    const db = g_app_db orelse return;
    const dest = if (dest_bundle_id) |ptr| std.mem.span(ptr) else return;
    // The log is an optimisation for the next suggestion, never a reason to
    // fail the paste the user just asked for.
    db.recordPaste(row_id, dest, was_suggested != 0, row_rank) catch |err| {
        std.debug.print("recordPaste failed: {s}\n", .{@errorName(err)});
    };
    if (sample_json) |ptr| {
        db.recordJevSample(dest, row_id, row_rank, suggested_row_id, std.mem.span(ptr)) catch |err| {
            std.debug.print("recordJevSample failed: {s}\n", .{@errorName(err)});
        };
    }
}

/// Fill `out` with the sequence facts for each of `ids` relative to
/// `dest_bundle_id`. Zeroes everything on any failure.
pub export fn mz_app_paste_signals(
    dest_bundle_id: ?[*:0]const u8,
    ids: ?[*]const i64,
    count: usize,
    out: ?[*]storage.Db.PasteSignals,
) void {
    const out_ptr = out orelse return;
    const out_slice = out_ptr[0..count];
    for (out_slice) |*o| o.* = .{};
    const db = g_app_db orelse return;
    const ids_ptr = ids orelse return;
    const dest = if (dest_bundle_id) |ptr| std.mem.span(ptr) else return;
    db.pasteSignalsForApp(dest, ids_ptr[0..count], nowUnix(), out_slice) catch {};
}

pub export fn mz_app_free_buffer(buffer: ?[*]const u8, len: usize) void {
    const ptr = buffer orelse return;
    if (len == 0) return;
    std.heap.c_allocator.free(@constCast(ptr[0..len]));
}

const ImportStats = struct { items: usize = 0, contents: usize = 0, skipped_blobs: usize = 0, skipped_items: usize = 0 };

fn defaultMaccySourcePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = if (c.getenv("HOME")) |home_c| std.mem.span(home_c) else ".";
    return std.fs.path.join(allocator, &.{ home, "Library", "Containers", "org.p0deje.Maccy", "Data", "Library", "Application Support", "Maccy", "Storage.sqlite" });
}

fn cmdImportMaccy(allocator: std.mem.Allocator, cfg: Config) !void {
    try ensureParent(cfg.db_path);
    const source_path = cfg.import_source_path orelse try defaultMaccySourcePath(allocator);
    var source = try Db.open(source_path);
    defer source.close();
    var dest = try Db.open(cfg.db_path);
    defer dest.close();
    try dest.migrate();
    const stats = try importMaccyDb(&source, &dest, cfg.max_blob_bytes);
    _ = try dest.prune(cfg.max_items);
    std.debug.print("imported items={} contents={} skipped_items={} skipped_blobs={} source={s} dest={s}\n", .{ stats.items, stats.contents, stats.skipped_items, stats.skipped_blobs, source_path, cfg.db_path });
}

fn importMaccyDb(source: *Db, dest: *Db, max_blob_bytes: usize) !ImportStats {
    var stats = ImportStats{};
    const item_stmt = try source.prepare(
        \\SELECT Z_PK, COALESCE(ZTITLE,''), COALESCE(ZAPPLICATION,''), COALESCE(ZPIN,''),
        \\       COALESCE(ZNUMBEROFCOPIES,1),
        \\       CAST(COALESCE(ZFIRSTCOPIEDAT,0)+978307200 AS INTEGER),
        \\       CAST(COALESCE(ZLASTCOPIEDAT,0)+978307200 AS INTEGER)
        \\FROM ZHISTORYITEM ORDER BY ZLASTCOPIEDAT DESC;
    );
    defer _ = sqlite.sqlite3_finalize(item_stmt);
    while (sqlite.sqlite3_step(item_stmt) == sqlite.SQLITE_ROW) {
        const old_id = sqlite.sqlite3_column_int64(item_stmt, 0);
        var blobs = std.ArrayList(BlobView).empty;
        defer blobs.deinit(std.heap.page_allocator);
        var copied_buffers = std.ArrayList([]u8).empty;
        defer {
            for (copied_buffers.items) |buf| std.heap.page_allocator.free(buf);
            copied_buffers.deinit(std.heap.page_allocator);
        }
        const content_stmt = try source.prepare("SELECT ZTYPE, ZVALUE, LENGTH(ZVALUE) FROM ZHISTORYITEMCONTENT WHERE ZITEM=?1 ORDER BY Z_PK ASC;");
        defer _ = sqlite.sqlite3_finalize(content_stmt);
        _ = sqlite.sqlite3_bind_int64(content_stmt, 1, old_id);
        while (sqlite.sqlite3_step(content_stmt) == sqlite.SQLITE_ROW) {
            const len_i = sqlite.sqlite3_column_int64(content_stmt, 2);
            if (len_i <= 0) continue;
            if (@as(usize, @intCast(len_i)) > max_blob_bytes) {
                stats.skipped_blobs += 1;
                continue;
            }
            const ty_raw = sqlite.sqlite3_column_text(content_stmt, 0) orelse continue;
            const blob_ptr = sqlite.sqlite3_column_blob(content_stmt, 1) orelse continue;
            const ty_copy = try std.heap.page_allocator.dupe(u8, std.mem.span(ty_raw));
            const data_copy = try std.heap.page_allocator.dupe(u8, @as([*]const u8, @ptrCast(blob_ptr))[0..@intCast(len_i)]);
            try copied_buffers.append(std.heap.page_allocator, ty_copy);
            try copied_buffers.append(std.heap.page_allocator, data_copy);
            try blobs.append(std.heap.page_allocator, .{
                .ty = ty_copy,
                .data = data_copy,
            });
        }
        if (blobs.items.len == 0) {
            stats.skipped_items += 1;
            continue;
        }
        const hash = capture_service.computeHashHex(blobs.items);
        const title_txt = sqlite.sqlite3_column_text(item_stmt, 1) orelse @as([*c]const u8, @ptrCast(""));
        const app_txt = sqlite.sqlite3_column_text(item_stmt, 2) orelse @as([*c]const u8, @ptrCast(""));
        const pin_txt = sqlite.sqlite3_column_text(item_stmt, 3) orelse @as([*c]const u8, @ptrCast(""));
        const inserted = try dest.insertImported(
            blobs.items,
            &hash,
            std.mem.span(title_txt),
            std.mem.span(app_txt),
            std.mem.span(pin_txt),
            sqlite.sqlite3_column_int64(item_stmt, 5),
            sqlite.sqlite3_column_int64(item_stmt, 6),
            sqlite.sqlite3_column_int64(item_stmt, 4),
            storage.classifyContentKind(blobs.items, std.mem.span(title_txt)),
        );
        if (inserted) {
            stats.items += 1;
            stats.contents += blobs.items.len;
        }
    }
    return stats;
}
