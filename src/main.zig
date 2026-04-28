const std = @import("std");
const capture_service = @import("capture_service.zig");
const storage = @import("storage.zig");
const c = @cImport({
    @cInclude("sqlite3.h");
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
    } else if (std.mem.eql(u8, cmd, "bench")) {
        try cmdBench(arena, cfg);
    } else {
        std.debug.print("unknown command: {s}\n\n", .{cmd});
        usage();
    }
}

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
        const result = try capture_service.captureClipboard(allocator, &db, .{
            .enabled_types = cfg.enabled_types,
            .max_blob_bytes = cfg.max_blob_bytes,
        }, &last_change);
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
            .skipped_self_generated, .skipped_empty, .no_change => {},
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

fn cmdApp(allocator: std.mem.Allocator, cfg: Config) !void {
    var effective_cfg = cfg;
    if (!effective_cfg.max_items_overridden) {
        effective_cfg.max_items = c.mz_app_load_max_items(effective_cfg.max_items);
    }
    c.mz_app_set_initial_max_items(effective_cfg.max_items);

    try ensureParent(effective_cfg.db_path);
    var db = try Db.open(effective_cfg.db_path);
    defer db.close();
    try db.migrate();

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
    const n = @min(q.len, g_app_query.len);
    @memset(&g_app_query, 0);
    @memcpy(g_app_query[0..n], q[0..n]);
    g_app_query_len = n;
    appRefreshRows() catch |err| {
        std.debug.print("appRefreshRows (search) failed: {s}\n", .{@errorName(err)});
    };
}

fn appOnSelect(id: i64, paste: c_int) callconv(.c) void {
    appWriteSelection(id, false, paste != 0) catch return;
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

fn appOnAction(action: c.MZAppAction, row_id: i64) callconv(.c) void {
    if (g_app_db) |db| {
        switch (action) {
            c.MZ_APP_ACTION_COPY => appWriteSelection(row_id, false, false) catch return,
            c.MZ_APP_ACTION_PASTE => appWriteSelection(row_id, false, true) catch return,
            c.MZ_APP_ACTION_PASTE_PLAIN => appWriteSelection(row_id, true, true) catch return,
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
        const removed = try db.prune(g_app_max_items);
        // The capacity cull may have evicted rows whose ids are about to be
        // reused on the next insert; drop their cached previews.
        if (removed > 0) c.mz_app_invalidate_preview_cache();
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
            if (removed > 0) {
                c.mz_app_invalidate_preview_cache();
                try appRefreshRows();
            }
        }
    }

    if (result.should_refresh_rows) {
        try appRefreshRows();
    }
}

fn appWriteSelection(id: i64, plain_only: bool, paste_after: bool) !void {
    const db = g_app_db orelse return;
    try db.writeItemToPasteboard(id, plain_only);
    if (paste_after and c.mz_ax_is_trusted(0) != 0) c.mz_post_command_v();
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

    const query = g_app_query[0..g_app_query_len];
    const stmt = g_refresh_stmt orelse blk: {
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
            \\       content_kind
            \\FROM history_items
            \\WHERE (?1 = '' OR title LIKE '%' || ?1 || '%' OR app LIKE '%' || ?1 || '%')
            \\ORDER BY last_copied_at DESC, id DESC
            \\LIMIT ?6;
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
    while (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
        const title_txt = sqlite.sqlite3_column_text(stmt, 1) orelse @as([*c]const u8, @ptrCast(""));
        const app_txt = sqlite.sqlite3_column_text(stmt, 2) orelse @as([*c]const u8, @ptrCast(""));
        const subtitle_txt = sqlite.sqlite3_column_text(stmt, 3) orelse @as([*c]const u8, @ptrCast(""));
        const title_z = try allocator.dupeZ(u8, std.mem.span(title_txt));
        const app_z = try allocator.dupeZ(u8, std.mem.span(app_txt));
        const subtitle_z = try allocator.dupeZ(u8, std.mem.span(subtitle_txt));
        try strings.append(allocator, title_z);
        try strings.append(allocator, app_z);
        try strings.append(allocator, subtitle_z);
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
