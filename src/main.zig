const std = @import("std");
const capture_service = @import("capture_service.zig");
const storage = @import("storage.zig");
const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("stdlib.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
    @cInclude("macos_app.h");
    @cInclude("macos_hotkey.h");
    @cInclude("macos_paste.h");
});

const Config = struct {
    db_path: []const u8,
    interval_ms: u64 = 500,
    max_items: i64 = 200,
    max_blob_bytes: usize = 16 * 1024 * 1024,
    once: bool = false,
    import_source_path: ?[]const u8 = null,
    enabled_types: []const []const u8 = &default_types,
};

const default_types = [_][]const u8{
    "public.file-url",
    "public.html",
    "public.png",
    "public.rtf",
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
        try cmdApp(arena, cfg);
        return;
    }
    if (std.mem.eql(u8, args[1], "help") or std.mem.eql(u8, args[1], "--help")) {
        usage();
        return;
    }

    const cmd = args[1];
    try parseOptions(args[2..], &cfg);

    if (std.mem.eql(u8, cmd, "app")) {
        try cmdApp(arena, cfg);
    } else if (std.mem.eql(u8, cmd, "import-maccy")) {
        try cmdImportMaccy(arena, cfg);
    } else if (std.mem.eql(u8, cmd, "watch")) {
        try cmdWatch(arena, cfg);
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
        \\  --max-items N        Unpinned history cap (default: 200)
        \\  --max-blob-mib N     Skip individual pasteboard blobs above N MiB (default: 16)
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
        } else if (std.mem.eql(u8, arg, "--max-blob-mib")) {
            i += 1;
            if (i >= args.len) return error.MissingMaxBlob;
            const mib = try std.fmt.parseInt(usize, args[i], 10);
            cfg.max_blob_bytes = mib * 1024 * 1024;
        } else if (std.mem.eql(u8, arg, "--no-images")) {
            cfg.enabled_types = &[_][]const u8{
                "public.file-url",
                "public.html",
                "public.rtf",
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

    var last_change: i64 = -1;
    while (true) {
        const result = try capture_service.captureClipboard(allocator, &db, .{
            .enabled_types = cfg.enabled_types,
            .max_blob_bytes = cfg.max_blob_bytes,
        }, &last_change);
        if (result.should_prune) {
            try db.prune(cfg.max_items);
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
    const cols = sqlite.sqlite3_column_count(stmt.?);
    while (sqlite.sqlite3_step(stmt.?) == sqlite.SQLITE_ROW) {
        var i: c_int = 0;
        while (i < cols) : (i += 1) {
            const name = sqlite.sqlite3_column_name(stmt.?, i);
            const txt = sqlite.sqlite3_column_text(stmt.?, i);
            std.debug.print("{s}=", .{std.mem.span(name)});
            if (txt != null) std.debug.print("{s}", .{std.mem.span(txt)}) else std.debug.print("NULL", .{});
            if (i + 1 < cols) std.debug.print("\t", .{});
        }
        std.debug.print("\n", .{});
    }
}

fn cmdBench(allocator: std.mem.Allocator, cfg: Config) !void {
    try ensureParent(cfg.db_path);
    var db = try Db.open(cfg.db_path);
    defer db.close();
    try db.migrate();

    const sizes = [_]usize{ 64, 1024, 64 * 1024, 1024 * 1024 };
    for (sizes) |size| {
        const data = try allocator.alloc(u8, size);
        defer allocator.free(data);
        @memset(data, @as(u8, @intCast(size & 0xff)));
        const blob = [_]BlobView{.{ .ty = "public.utf8-plain-text", .data = data }};
        const hash = capture_service.computeHashHex(&blob);
        var title: [256]u8 = [_]u8{0} ** 256;
        const label = try std.fmt.bufPrint(title[0..], "bench {d} bytes", .{size});
        if (label.len < title.len) title[label.len] = 0;
        _ = try db.upsertCapture(&blob, &hash, &title, "bench");
    }
    try db.prune(cfg.max_items);
    std.debug.print("bench complete db={s}\n", .{cfg.db_path});
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
var g_app_max_items: i64 = 200;
var g_app_max_blob_bytes: usize = 16 * 1024 * 1024;
var g_app_enabled_types: []const []const u8 = &default_types;

fn cmdApp(allocator: std.mem.Allocator, cfg: Config) !void {
    try ensureParent(cfg.db_path);
    var db = try Db.open(cfg.db_path);
    defer db.close();
    try db.migrate();
    g_app_db = &db;
    g_app_allocator = allocator;
    g_app_max_items = cfg.max_items;
    g_app_max_blob_bytes = cfg.max_blob_bytes;
    g_app_enabled_types = cfg.enabled_types;

    const callbacks = c.MZAppCallbacks{
        .on_toggle = appOnToggle,
        .on_poll = appOnPoll,
        .on_search = appOnSearch,
        .on_select = appOnSelect,
        .on_clear = appOnClear,
        .on_quit = appOnQuit,
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
    appRefreshRows() catch {};
}

fn appOnPoll() callconv(.c) void {
    appPollClipboard() catch {};
}

fn appOnSearch(query: [*c]const u8) callconv(.c) void {
    const q = if (query != null) std.mem.span(query) else "";
    const n = @min(q.len, g_app_query.len);
    @memset(&g_app_query, 0);
    @memcpy(g_app_query[0..n], q[0..n]);
    g_app_query_len = n;
    appRefreshRows() catch {};
}

fn appOnSelect(id: i64, paste: c_int) callconv(.c) void {
    appWriteSelection(id, false, paste != 0) catch return;
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
                appRefreshRows() catch {};
            },
            c.MZ_APP_ACTION_CLEAR_ALL => {
                db.clearAll() catch return;
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
        try db.prune(g_app_max_items);
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
    const sql =
        \\SELECT id,
        \\       title,
        \\       COALESCE(app, ''),
        \\       CASE
        \\         WHEN EXISTS(
        \\           SELECT 1 FROM history_contents c
        \\           WHERE c.item_id=history_items.id
        \\             AND (c.type LIKE '%png%' OR c.type LIKE '%tiff%' OR c.type LIKE '%jpeg%' OR c.type LIKE '%heic%')
        \\         ) THEN 'Copied as Image'
        \\         WHEN EXISTS(
        \\           SELECT 1 FROM history_contents c
        \\           WHERE c.item_id=history_items.id AND c.type='public.file-url'
        \\         ) THEN 'Copied as File'
        \\         WHEN COALESCE(app, '') <> '' THEN app
        \\         WHEN title LIKE 'http://%' OR title LIKE 'https://%' OR EXISTS(
        \\           SELECT 1 FROM history_contents c
        \\           WHERE c.item_id=history_items.id AND (c.type LIKE '%url%' OR c.type LIKE '%html%')
        \\         ) THEN 'Copied as Link'
        \\         WHEN EXISTS(
        \\           SELECT 1 FROM history_contents c
        \\           WHERE c.item_id=history_items.id AND (c.type='public.utf8-plain-text' OR c.type LIKE '%rtf%' OR c.type LIKE '%text%')
        \\         ) THEN 'Copied as Plain Text'
        \\         ELSE 'Copied Data'
        \\       END AS subtitle,
        \\       pin IS NOT NULL AS is_pinned,
        \\       copy_count,
        \\       last_copied_at,
        \\       EXISTS(
        \\         SELECT 1 FROM history_contents c
        \\         WHERE c.item_id=history_items.id
        \\           AND (c.type LIKE '%png%' OR c.type LIKE '%tiff%' OR c.type LIKE '%jpeg%' OR c.type LIKE '%heic%')
        \\       ) AS has_image,
        \\       CASE
        \\         WHEN EXISTS(
        \\           SELECT 1 FROM history_contents c
        \\           WHERE c.item_id=history_items.id
        \\             AND (c.type LIKE '%png%' OR c.type LIKE '%tiff%' OR c.type LIKE '%jpeg%' OR c.type LIKE '%heic%')
        \\         ) THEN ?2
        \\         WHEN EXISTS(
        \\           SELECT 1 FROM history_contents c
        \\           WHERE c.item_id=history_items.id AND c.type='public.file-url'
        \\         ) THEN ?3
        \\         WHEN title LIKE 'http://%' OR title LIKE 'https://%' OR EXISTS(
        \\           SELECT 1 FROM history_contents c
        \\           WHERE c.item_id=history_items.id AND (c.type LIKE '%url%' OR c.type LIKE '%html%')
        \\         ) THEN ?4
        \\         WHEN EXISTS(
        \\           SELECT 1 FROM history_contents c
        \\           WHERE c.item_id=history_items.id AND (c.type='public.utf8-plain-text' OR c.type LIKE '%rtf%' OR c.type LIKE '%text%')
        \\         ) THEN ?5
        \\         ELSE ?6
        \\       END AS content_kind
        \\FROM history_items
        \\WHERE (?1 = '' OR title LIKE '%' || ?1 || '%' OR app LIKE '%' || ?1 || '%')
        \\ORDER BY (pin IS NULL), last_copied_at DESC
        \\LIMIT 200;
    ;
    const stmt = try db.prepare(sql);
    defer _ = sqlite.sqlite3_finalize(stmt);
    try storage.bindText(stmt, 1, query);
    _ = sqlite.sqlite3_bind_int(stmt, 2, c.MZ_APP_CONTENT_IMAGE);
    _ = sqlite.sqlite3_bind_int(stmt, 3, c.MZ_APP_CONTENT_FILE);
    _ = sqlite.sqlite3_bind_int(stmt, 4, c.MZ_APP_CONTENT_LINK);
    _ = sqlite.sqlite3_bind_int(stmt, 5, c.MZ_APP_CONTENT_TEXT);
    _ = sqlite.sqlite3_bind_int(stmt, 6, c.MZ_APP_CONTENT_OTHER);
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
            .content_kind = sqlite.sqlite3_column_int(stmt, 8),
            .pinned = sqlite.sqlite3_column_int(stmt, 4),
            .has_image = sqlite.sqlite3_column_int(stmt, 7),
            .copy_count = sqlite.sqlite3_column_int(stmt, 5),
        });
    }
    c.mz_app_set_rows(rows.items.ptr, rows.items.len);
    c.mz_app_set_status_text("M");
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
    try dest.prune(cfg.max_items);
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
        );
        if (inserted) {
            stats.items += 1;
            stats.contents += blobs.items.len;
        }
    }
    return stats;
}
