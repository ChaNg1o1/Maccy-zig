const std = @import("std");
pub const sqlite = @cImport({
    @cInclude("sqlite3.h");
});
const c = @cImport({
    @cInclude("time.h");
    @cInclude("macos_clipboard.h");
});

pub const BlobView = struct {
    ty: []const u8,
    data: []const u8,
};

pub const ContentKind = enum(c_int) {
    text = 1,
    link = 2,
    image = 3,
    file = 4,
    other = 5,
};

pub const Db = struct {
    handle: *sqlite.sqlite3,
    cached: [@typeInfo(CachedKey).@"enum".fields.len]?*sqlite.sqlite3_stmt = .{null} ** @typeInfo(CachedKey).@"enum".fields.len,
    const pinned_marker = "pinned";

    pub const UpsertOutcome = enum {
        inserted,
        duplicate,
    };

    /// Hot statements that get prepared once per connection and reused via
    /// `sqlite3_reset` + `sqlite3_clear_bindings`. Keep in sync with
    /// `cachedSqlFor` below.
    pub const CachedKey = enum(u8) {
        update_duplicate,
        insert_history_item,
        insert_history_content,
        prune_capacity,
    };

    fn cachedSqlFor(key: CachedKey) [:0]const u8 {
        return switch (key) {
            .update_duplicate => "UPDATE history_items SET last_copied_at=?1, copy_count=copy_count+1 WHERE hash=?2;",
            .insert_history_item => "INSERT INTO history_items(hash,title,app,first_copied_at,last_copied_at,copy_count,content_kind) VALUES(?1,?2,?3,?4,?5,1,?6);",
            .insert_history_content => "INSERT INTO history_contents(item_id,type,value) VALUES(?1,?2,?3);",
            .prune_capacity =>
                \\DELETE FROM history_items
                \\WHERE pin IS NULL AND id IN (
                \\  SELECT id FROM history_items WHERE pin IS NULL
                \\  ORDER BY last_copied_at DESC LIMIT -1 OFFSET ?1
                \\);
            ,
        };
    }

    pub fn open(path: []const u8) !Db {
        var db: ?*sqlite.sqlite3 = null;
        const zpath = try std.heap.page_allocator.dupeZ(u8, path);
        defer std.heap.page_allocator.free(zpath);
        if (sqlite.sqlite3_open(zpath.ptr, &db) != sqlite.SQLITE_OK) return error.SqliteOpenFailed;
        return .{ .handle = db.? };
    }

    pub fn close(self: *Db) void {
        for (self.cached, 0..) |maybe, idx| {
            if (maybe) |stmt| _ = sqlite.sqlite3_finalize(stmt);
            self.cached[idx] = null;
        }
        _ = sqlite.sqlite3_close(self.handle);
    }

    /// Returns a reset, fresh-bound cached statement. Caller must NOT finalize.
    fn cachedStmt(self: *Db, key: CachedKey) !*sqlite.sqlite3_stmt {
        const idx = @intFromEnum(key);
        if (self.cached[idx]) |stmt| {
            _ = sqlite.sqlite3_reset(stmt);
            _ = sqlite.sqlite3_clear_bindings(stmt);
            return stmt;
        }
        const stmt = try self.prepare(cachedSqlFor(key));
        self.cached[idx] = stmt;
        return stmt;
    }

    pub fn migrate(self: *Db) !void {
        try self.exec(
            \\PRAGMA journal_mode=WAL;
            \\PRAGMA synchronous=NORMAL;
            \\PRAGMA foreign_keys=ON;
            \\PRAGMA temp_store=MEMORY;
            \\PRAGMA cache_size=-32768;
            \\PRAGMA mmap_size=67108864;
            \\PRAGMA wal_autocheckpoint=2000;
            \\PRAGMA journal_size_limit=33554432;
            \\PRAGMA checkpoint_fullfsync=OFF;
            \\PRAGMA fullfsync=OFF;
            \\CREATE TABLE IF NOT EXISTS history_items (
            \\  id INTEGER PRIMARY KEY,
            \\  hash TEXT NOT NULL UNIQUE,
            \\  title TEXT NOT NULL,
            \\  app TEXT,
            \\  first_copied_at INTEGER NOT NULL,
            \\  last_copied_at INTEGER NOT NULL,
            \\  copy_count INTEGER NOT NULL DEFAULT 1,
            \\  content_kind INTEGER NOT NULL DEFAULT 5,
            \\  pin_order INTEGER,
            \\  pin TEXT
            \\);
            \\CREATE TABLE IF NOT EXISTS history_contents (
            \\  id INTEGER PRIMARY KEY,
            \\  item_id INTEGER NOT NULL REFERENCES history_items(id) ON DELETE CASCADE,
            \\  type TEXT NOT NULL,
            \\  value BLOB NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_history_items_last ON history_items(last_copied_at DESC);
            \\CREATE INDEX IF NOT EXISTS idx_history_contents_item ON history_contents(item_id);
            \\CREATE INDEX IF NOT EXISTS idx_history_items_list ON history_items(last_copied_at DESC, id DESC, title, app, copy_count);
        );
        try self.ensureHistoryItemsContentKind();
        try self.ensureHistoryItemsPinOrder();
    }

    pub fn exec(self: *Db, sql: [:0]const u8) !void {
        var err: [*c]u8 = null;
        if (sqlite.sqlite3_exec(self.handle, sql.ptr, null, null, &err) != sqlite.SQLITE_OK) {
            if (err != null) sqlite.sqlite3_free(err);
            return error.SqliteExecFailed;
        }
    }

    pub fn upsertCapture(self: *Db, blobs: []const BlobView, hash_hex: *const [64]u8, title_buf: *const [256]u8, app: []const u8, content_kind: ContentKind) !UpsertOutcome {
        const now: i64 = @intCast(c.time(null));
        if (try self.updateDuplicate(hash_hex, now)) return .duplicate;

        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};

        const stmt = try self.cachedStmt(.insert_history_item);
        try bindText(stmt, 1, hash_hex[0..]);
        try bindText(stmt, 2, std.mem.sliceTo(title_buf, 0));
        try bindText(stmt, 3, app);
        _ = sqlite.sqlite3_bind_int64(stmt, 4, now);
        _ = sqlite.sqlite3_bind_int64(stmt, 5, now);
        _ = sqlite.sqlite3_bind_int(stmt, 6, @intFromEnum(content_kind));
        try stepDone(stmt);

        const item_id = sqlite.sqlite3_last_insert_rowid(self.handle);
        for (blobs) |blob| {
            const cstmt = try self.cachedStmt(.insert_history_content);
            _ = sqlite.sqlite3_bind_int64(cstmt, 1, item_id);
            try bindText(cstmt, 2, blob.ty);
            try bindBlob(cstmt, 3, blob.data);
            try stepDone(cstmt);
        }
        try self.exec("COMMIT;");
        return .inserted;
    }

    pub fn insertImported(self: *Db, blobs: []const BlobView, hash_hex: *const [64]u8, title: []const u8, app: []const u8, pin: []const u8, first_ts: i64, last_ts: i64, copy_count: i64, content_kind: ContentKind) !bool {
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};
        const stmt = try self.prepare("INSERT OR IGNORE INTO history_items(hash,title,app,first_copied_at,last_copied_at,copy_count,pin,content_kind,pin_order) VALUES(?1,?2,?3,?4,?5,?6,NULLIF(?7,''),?8,CASE WHEN NULLIF(?7,'') IS NULL THEN NULL ELSE ?5 END);");
        defer _ = sqlite.sqlite3_finalize(stmt);
        try bindText(stmt, 1, hash_hex[0..]);
        try bindText(stmt, 2, title);
        try bindText(stmt, 3, app);
        _ = sqlite.sqlite3_bind_int64(stmt, 4, first_ts);
        _ = sqlite.sqlite3_bind_int64(stmt, 5, last_ts);
        _ = sqlite.sqlite3_bind_int64(stmt, 6, if (copy_count <= 0) 1 else copy_count);
        try bindText(stmt, 7, pin);
        _ = sqlite.sqlite3_bind_int(stmt, 8, @intFromEnum(content_kind));
        try stepDone(stmt);
        if (sqlite.sqlite3_changes(self.handle) == 0) {
            try self.exec("COMMIT;");
            return false;
        }
        const item_id = sqlite.sqlite3_last_insert_rowid(self.handle);
        const cstmt = try self.prepare("INSERT INTO history_contents(item_id,type,value) VALUES(?1,?2,?3);");
        defer _ = sqlite.sqlite3_finalize(cstmt);
        for (blobs) |blob| {
            _ = sqlite.sqlite3_reset(cstmt);
            _ = sqlite.sqlite3_clear_bindings(cstmt);
            _ = sqlite.sqlite3_bind_int64(cstmt, 1, item_id);
            try bindText(cstmt, 2, blob.ty);
            try bindBlob(cstmt, 3, blob.data);
            try stepDone(cstmt);
        }
        try self.exec("COMMIT;");
        return true;
    }

    fn updateDuplicate(self: *Db, hash_hex: *const [64]u8, now: i64) !bool {
        const stmt = try self.cachedStmt(.update_duplicate);
        _ = sqlite.sqlite3_bind_int64(stmt, 1, now);
        try bindText(stmt, 2, hash_hex[0..]);
        try stepDone(stmt);
        return sqlite.sqlite3_changes(self.handle) > 0;
    }

    pub fn prune(self: *Db, max_items: i64) !i64 {
        const stmt = try self.cachedStmt(.prune_capacity);
        _ = sqlite.sqlite3_bind_int64(stmt, 1, max_items);
        try stepDone(stmt);
        return @intCast(sqlite.sqlite3_changes(self.handle));
    }

    /// Drop unpinned history rows whose `last_copied_at` is older than `cutoff_unix`.
    /// Pinned items are always preserved regardless of age. Returns the number of rows deleted.
    pub fn pruneOlderThan(self: *Db, cutoff_unix: i64) !i64 {
        const stmt = try self.prepare(
            "DELETE FROM history_items WHERE pin IS NULL AND last_copied_at < ?1;",
        );
        defer _ = sqlite.sqlite3_finalize(stmt);
        _ = sqlite.sqlite3_bind_int64(stmt, 1, cutoff_unix);
        try stepDone(stmt);
        return @intCast(sqlite.sqlite3_changes(self.handle));
    }

    pub fn clearAll(self: *Db) !void {
        try self.exec("DELETE FROM history_items;");
    }

    pub fn clearUnpinned(self: *Db) !void {
        try self.exec("DELETE FROM history_items WHERE pin IS NULL;");
    }

    pub fn togglePin(self: *Db, id: i64) !bool {
        const stmt = try self.prepare(
            \\UPDATE history_items
            \\SET pin = CASE WHEN pin IS NULL THEN ?1 ELSE NULL END,
            \\    pin_order = CASE
            \\        WHEN pin IS NULL THEN (SELECT COALESCE(MAX(pin_order), 0) + 1 FROM history_items)
            \\        ELSE NULL
            \\    END
            \\WHERE id=?2;
        );
        defer _ = sqlite.sqlite3_finalize(stmt);
        try bindText(stmt, 1, pinned_marker);
        _ = sqlite.sqlite3_bind_int64(stmt, 2, id);
        try stepDone(stmt);
        return sqlite.sqlite3_changes(self.handle) > 0;
    }

    pub fn writeItemToPasteboard(self: *Db, id: i64, plain_only: bool) !void {
        const stmt = try self.prepare("SELECT type, value FROM history_contents WHERE item_id=?1 ORDER BY id ASC;");
        defer _ = sqlite.sqlite3_finalize(stmt);
        _ = sqlite.sqlite3_bind_int64(stmt, 1, id);
        const allocator = std.heap.page_allocator;
        var blobs = std.ArrayList(c.MZBlob).empty;
        defer blobs.deinit(allocator);
        var owned_types = std.ArrayList([:0]u8).empty;
        defer {
            for (owned_types.items) |ty| allocator.free(ty);
            owned_types.deinit(allocator);
        }
        var owned_data = std.ArrayList([]u8).empty;
        defer {
            for (owned_data.items) |data| allocator.free(data);
            owned_data.deinit(allocator);
        }
        var has_url_blob = false;
        var inferred_url: ?[]u8 = null;
        defer if (inferred_url) |url| allocator.free(url);
        while (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            const ty_raw = sqlite.sqlite3_column_text(stmt, 0) orelse continue;
            const ty = std.mem.span(ty_raw);
            if (isUrlType(ty)) has_url_blob = true;
            if (plain_only and !(std.mem.eql(u8, ty, "public.utf8-plain-text") or std.mem.eql(u8, ty, "public.file-url"))) continue;
            const len_i = sqlite.sqlite3_column_bytes(stmt, 1);
            if (len_i <= 0) continue;
            const blob_ptr = sqlite.sqlite3_column_blob(stmt, 1) orelse continue;
            const len: usize = @intCast(len_i);
            const bytes = @as([*]const u8, @ptrCast(blob_ptr))[0..len];
            if (!plain_only and inferred_url == null) {
                if (extractHttpUrl(bytes)) |url| inferred_url = try allocator.dupe(u8, url);
            }
            const ty_copy = try allocator.dupeZ(u8, ty);
            const data_copy = try allocator.dupe(u8, bytes);
            try owned_types.append(allocator, ty_copy);
            try owned_data.append(allocator, data_copy);
            try blobs.append(allocator, .{
                .type = ty_copy.ptr,
                .data = data_copy.ptr,
                .len = @intCast(len_i),
            });
        }
        if (!plain_only and !has_url_blob) {
            if (inferred_url) |url| {
                const ty_copy = try allocator.dupeZ(u8, "public.url");
                const data_copy = try allocator.dupe(u8, url);
                try owned_types.append(allocator, ty_copy);
                try owned_data.append(allocator, data_copy);
                try blobs.append(allocator, .{
                    .type = ty_copy.ptr,
                    .data = data_copy.ptr,
                    .len = @intCast(data_copy.len),
                });
            }
        }
        if (blobs.items.len == 0) return error.NoPasteboardContent;
        try writeBlobArrayToPasteboard(blobs.items, "org.p0deje.Maccy");
    }

    pub fn readRevealTarget(self: *Db, id: i64, allocator: std.mem.Allocator) !?[]u8 {
        const stmt = try self.prepare(
            \\SELECT value
            \\FROM history_contents
            \\WHERE item_id=?1 AND (type='public.file-url' OR type LIKE '%url%')
            \\ORDER BY CASE WHEN type='public.file-url' THEN 0 ELSE 1 END, id ASC
            \\LIMIT 1;
        );
        defer _ = sqlite.sqlite3_finalize(stmt);
        _ = sqlite.sqlite3_bind_int64(stmt, 1, id);

        return switch (sqlite.sqlite3_step(stmt)) {
            sqlite.SQLITE_ROW => blk: {
                const bytes_i = sqlite.sqlite3_column_bytes(stmt, 0);
                if (bytes_i <= 0) break :blk null;
                const blob_ptr = sqlite.sqlite3_column_blob(stmt, 0) orelse break :blk null;
                break :blk try allocator.dupe(u8, @as([*]const u8, @ptrCast(blob_ptr))[0..@intCast(bytes_i)]);
            },
            sqlite.SQLITE_DONE => null,
            else => error.SqliteStepFailed,
        };
    }

    pub fn readImagePreview(self: *Db, id: i64, allocator: std.mem.Allocator) !?[]u8 {
        const stmt = try self.prepare(
            \\SELECT value
            \\FROM history_contents
            \\WHERE item_id=?1
            \\  AND (
            \\    type LIKE '%png%' OR
            \\    type LIKE '%tiff%' OR
            \\    type LIKE '%jpeg%' OR
            \\    type LIKE '%jpg%' OR
            \\    type LIKE '%heic%'
            \\  )
            \\ORDER BY id ASC
            \\LIMIT 1;
        );
        defer _ = sqlite.sqlite3_finalize(stmt);
        _ = sqlite.sqlite3_bind_int64(stmt, 1, id);

        return switch (sqlite.sqlite3_step(stmt)) {
            sqlite.SQLITE_ROW => blk: {
                const bytes_i = sqlite.sqlite3_column_bytes(stmt, 0);
                if (bytes_i <= 0) break :blk null;
                const blob_ptr = sqlite.sqlite3_column_blob(stmt, 0) orelse break :blk null;
                break :blk try allocator.dupe(u8, @as([*]const u8, @ptrCast(blob_ptr))[0..@intCast(bytes_i)]);
            },
            sqlite.SQLITE_DONE => null,
            else => error.SqliteStepFailed,
        };
    }

    pub fn prepare(self: *Db, sql: [:0]const u8) !*sqlite.sqlite3_stmt {
        var stmt: ?*sqlite.sqlite3_stmt = null;
        if (sqlite.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != sqlite.SQLITE_OK) return error.SqlitePrepareFailed;
        return stmt.?;
    }

    /// Bump whenever `classifyContentKind` semantics change so existing rows
    /// get reclassified on next launch (via `PRAGMA user_version`).
    /// History:
    ///   1 — initial classify rules (added with the column)
    ///   2 — link requires explicit public.url / http(s) title; html/url-name no
    ///       longer flag a row as a link
    const CLASSIFY_RULES_VERSION: i64 = 2;

    fn ensureHistoryItemsContentKind(self: *Db) !void {
        const had_column = try self.tableHasColumn("history_items", "content_kind");
        if (!had_column) {
            try self.exec("ALTER TABLE history_items ADD COLUMN content_kind INTEGER NOT NULL DEFAULT 5;");
            try self.backfillHistoryItemsContentKind();
            try self.setUserVersion(CLASSIFY_RULES_VERSION);
            return;
        }
        const stored = try self.userVersion();
        if (stored < CLASSIFY_RULES_VERSION) {
            try self.backfillHistoryItemsContentKind();
            try self.setUserVersion(CLASSIFY_RULES_VERSION);
        }
    }

    fn userVersion(self: *Db) !i64 {
        const stmt = try self.prepare("PRAGMA user_version;");
        defer _ = sqlite.sqlite3_finalize(stmt);
        if (sqlite.sqlite3_step(stmt) != sqlite.SQLITE_ROW) return 0;
        return sqlite.sqlite3_column_int64(stmt, 0);
    }

    fn setUserVersion(self: *Db, value: i64) !void {
        var sql_buf: [64]u8 = undefined;
        const sql = try std.fmt.bufPrintZ(&sql_buf, "PRAGMA user_version = {d};", .{value});
        try self.exec(sql);
    }

    fn ensureHistoryItemsPinOrder(self: *Db) !void {
        if (!(try self.tableHasColumn("history_items", "pin_order"))) {
            try self.exec("ALTER TABLE history_items ADD COLUMN pin_order INTEGER;");
        }
        try self.backfillHistoryItemsPinOrder();
    }

    fn tableHasColumn(self: *Db, table_name: []const u8, column_name: []const u8) !bool {
        var sql_buf: [128]u8 = undefined;
        const sql = try std.fmt.bufPrintZ(&sql_buf, "PRAGMA table_info({s});", .{table_name});
        const stmt = try self.prepare(sql);
        defer _ = sqlite.sqlite3_finalize(stmt);
        while (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            const name = sqlite.sqlite3_column_text(stmt, 1) orelse continue;
            if (std.mem.eql(u8, std.mem.span(name), column_name)) return true;
        }
        return false;
    }

    fn backfillHistoryItemsContentKind(self: *Db) !void {
        // Priority and rules must mirror `classifyContentKind` above; the test
        // "classifyContentKind uses the same priority as the app query" guards
        // against drift between the two.
        try self.exec(
            \\UPDATE history_items
            \\SET content_kind = CASE
            \\  WHEN EXISTS(
            \\    SELECT 1 FROM history_contents c
            \\    WHERE c.item_id=history_items.id
            \\      AND (c.type LIKE '%png%' OR c.type LIKE '%tiff%' OR c.type LIKE '%jpeg%' OR c.type LIKE '%heic%')
            \\  ) THEN 3
            \\  WHEN EXISTS(
            \\    SELECT 1 FROM history_contents c
            \\    WHERE c.item_id=history_items.id AND c.type='public.file-url'
            \\  ) THEN 4
            \\  WHEN title LIKE 'http://%' OR title LIKE 'https://%' OR EXISTS(
            \\    SELECT 1 FROM history_contents c
            \\    WHERE c.item_id=history_items.id AND c.type='public.url'
            \\  ) THEN 2
            \\  WHEN EXISTS(
            \\    SELECT 1 FROM history_contents c
            \\    WHERE c.item_id=history_items.id
            \\      AND (c.type='public.utf8-plain-text'
            \\           OR c.type LIKE '%rtf%'
            \\           OR c.type LIKE '%text%'
            \\           OR c.type LIKE '%html%'
            \\           OR c.type LIKE '%url-name%')
            \\  ) THEN 1
            \\  ELSE 5
            \\END;
        );
    }

    fn backfillHistoryItemsPinOrder(self: *Db) !void {
        try self.exec(
            \\UPDATE history_items
            \\SET pin_order = last_copied_at
            \\WHERE pin IS NOT NULL AND pin_order IS NULL;
        );
    }
};

pub fn classifyContentKind(blobs: []const BlobView, title: []const u8) ContentKind {
    // Priority: image > file > link > text > other.
    //
    // "Link" must be a real, paste-as-URL value -- not "anything that happens to
    // carry HTML markup or a URL display name". Otherwise plain rich-text copies
    // from Lark/Slack/web pages get mis-bucketed into the Links tab. We therefore
    // require either an explicit `public.url` flavor or a plain-text payload that
    // is itself a URL (title starts with http:// or https://).
    var saw_file = false;
    var saw_explicit_url = false;
    var saw_text = false;

    for (blobs) |blob| {
        if (isImageType(blob.ty)) return .image;
        if (std.mem.eql(u8, blob.ty, "public.file-url")) saw_file = true;
        if (std.mem.eql(u8, blob.ty, "public.url")) saw_explicit_url = true;
        if (std.mem.eql(u8, blob.ty, "public.utf8-plain-text") or
            std.mem.indexOf(u8, blob.ty, "rtf") != null or
            std.mem.indexOf(u8, blob.ty, "text") != null or
            std.mem.indexOf(u8, blob.ty, "html") != null or
            std.mem.indexOf(u8, blob.ty, "url-name") != null)
        {
            saw_text = true;
        }
    }

    if (saw_file) return .file;
    if (saw_explicit_url or startsWithHttpScheme(title)) return .link;
    if (saw_text) return .text;
    return .other;
}

fn startsWithHttpScheme(title: []const u8) bool {
    return std.mem.startsWith(u8, title, "http://") or std.mem.startsWith(u8, title, "https://");
}

fn isUrlType(ty: []const u8) bool {
    return std.mem.eql(u8, ty, "public.url") or
        std.mem.eql(u8, ty, "public.file-url") or
        std.mem.eql(u8, ty, "public.url-name");
}

fn isImageType(ty: []const u8) bool {
    return std.mem.indexOf(u8, ty, "png") != null or
        std.mem.indexOf(u8, ty, "tiff") != null or
        std.mem.indexOf(u8, ty, "jpeg") != null or
        std.mem.indexOf(u8, ty, "heic") != null;
}

fn extractHttpUrl(bytes: []const u8) ?[]const u8 {
    const https_idx = std.mem.indexOf(u8, bytes, "https://");
    const http_idx = std.mem.indexOf(u8, bytes, "http://");
    const start = switch (https_idx != null or http_idx != null) {
        true => if (https_idx) |idx|
            if (http_idx) |http| @min(idx, http) else idx
        else
            http_idx.?,
        false => return null,
    };

    var end = start;
    while (end < bytes.len) : (end += 1) {
        const ch = bytes[end];
        if (ch <= 0x20 or ch == '"' or ch == '\'' or ch == '<' or ch == '>' or ch == ')' or ch == ']') break;
    }
    if (end <= start) return null;
    return bytes[start..end];
}

pub fn bindText(stmt: *sqlite.sqlite3_stmt, idx: c_int, value: []const u8) !void {
    if (sqlite.sqlite3_bind_text(stmt, idx, value.ptr, @intCast(value.len), null) != sqlite.SQLITE_OK) return error.SqliteBindFailed;
}

pub fn bindBlob(stmt: *sqlite.sqlite3_stmt, idx: c_int, value: []const u8) !void {
    if (sqlite.sqlite3_bind_blob(stmt, idx, value.ptr, @intCast(value.len), null) != sqlite.SQLITE_OK) return error.SqliteBindFailed;
}

pub fn stepDone(stmt: *sqlite.sqlite3_stmt) !void {
    const rc = sqlite.sqlite3_step(stmt);
    if (rc != sqlite.SQLITE_DONE) return error.SqliteStepFailed;
}

fn writeBlobArrayToPasteboard(blobs: []c.MZBlob, source: []const u8) !void {
    const source_z = try std.heap.page_allocator.dupeZ(u8, source);
    defer std.heap.page_allocator.free(source_z);
    if (c.mz_clipboard_write(blobs.ptr, blobs.len, source_z.ptr) != 0) return error.PasteboardWriteFailed;
}

fn testFetchPin(db: *Db, id: i64, allocator: std.mem.Allocator) !?[]u8 {
    const stmt = try db.prepare("SELECT pin FROM history_items WHERE id=?1;");
    defer _ = sqlite.sqlite3_finalize(stmt);
    _ = sqlite.sqlite3_bind_int64(stmt, 1, id);
    return switch (sqlite.sqlite3_step(stmt)) {
        sqlite.SQLITE_ROW => if (sqlite.sqlite3_column_text(stmt, 0)) |pin_txt|
            try allocator.dupe(u8, std.mem.span(pin_txt))
        else
            null,
        sqlite.SQLITE_DONE => null,
        else => error.SqliteStepFailed,
    };
}

fn testFetchPinOrder(db: *Db, id: i64) !?i64 {
    const stmt = try db.prepare("SELECT pin_order FROM history_items WHERE id=?1;");
    defer _ = sqlite.sqlite3_finalize(stmt);
    _ = sqlite.sqlite3_bind_int64(stmt, 1, id);
    return switch (sqlite.sqlite3_step(stmt)) {
        sqlite.SQLITE_ROW => if (sqlite.sqlite3_column_type(stmt, 0) == sqlite.SQLITE_NULL)
            null
        else
            sqlite.sqlite3_column_int64(stmt, 0),
        sqlite.SQLITE_DONE => null,
        else => error.SqliteStepFailed,
    };
}

fn testFetchInt(db: *Db, sql: [:0]const u8) !i64 {
    const stmt = try db.prepare(sql);
    defer _ = sqlite.sqlite3_finalize(stmt);
    if (sqlite.sqlite3_step(stmt) != sqlite.SQLITE_ROW) return error.SqliteStepFailed;
    return sqlite.sqlite3_column_int64(stmt, 0);
}

test "togglePin stores stable marker and null" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.migrate();

    const blobs = [_]BlobView{.{ .ty = "public.utf8-plain-text", .data = "hello" }};
    const hash = [_]u8{'a'} ** 64;
    try std.testing.expect(try db.insertImported(&blobs, &hash, "title", "app", "", 1, 1, 1, .text));

    const item_id = sqlite.sqlite3_last_insert_rowid(db.handle);
    try std.testing.expectEqual(@as(i64, 1), item_id);
    try std.testing.expectEqual(@as(?[]u8, null), try testFetchPin(&db, item_id, std.testing.allocator));

    try std.testing.expect(try db.togglePin(item_id));
    const pinned = (try testFetchPin(&db, item_id, std.testing.allocator)).?;
    defer std.testing.allocator.free(pinned);
    try std.testing.expectEqualStrings(Db.pinned_marker, pinned);
    const first_pin_order = (try testFetchPinOrder(&db, item_id)).?;
    try std.testing.expect(first_pin_order > 0);

    try std.testing.expect(try db.togglePin(item_id));
    try std.testing.expectEqual(@as(?[]u8, null), try testFetchPin(&db, item_id, std.testing.allocator));
    try std.testing.expectEqual(@as(?i64, null), try testFetchPinOrder(&db, item_id));
}

test "togglePin returns false for missing row" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.migrate();

    try std.testing.expect(!(try db.togglePin(99)));
}

test "togglePin promotes newly pinned items ahead of older pinned items" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.migrate();

    const blobs = [_]BlobView{.{ .ty = "public.utf8-plain-text", .data = "hello" }};
    const hash_a = [_]u8{'a'} ** 64;
    const hash_b = [_]u8{'b'} ** 64;
    try std.testing.expect(try db.insertImported(&blobs, &hash_a, "title a", "app", "", 1, 1, 1, .text));
    const item_a = sqlite.sqlite3_last_insert_rowid(db.handle);
    try std.testing.expect(try db.insertImported(&blobs, &hash_b, "title b", "app", "", 2, 2, 1, .text));
    const item_b = sqlite.sqlite3_last_insert_rowid(db.handle);

    try std.testing.expect(try db.togglePin(item_a));
    const order_a = (try testFetchPinOrder(&db, item_a)).?;
    try std.testing.expect(try db.togglePin(item_b));
    const order_b = (try testFetchPinOrder(&db, item_b)).?;
    try std.testing.expect(order_b > order_a);
}

test "classifyContentKind uses the same priority as the app query" {
    const image = [_]BlobView{.{ .ty = "public.png", .data = "img" }};
    try std.testing.expectEqual(ContentKind.image, classifyContentKind(&image, "note"));

    const file = [_]BlobView{.{ .ty = "public.file-url", .data = "file:///tmp/a" }};
    try std.testing.expectEqual(ContentKind.file, classifyContentKind(&file, "note"));

    // Real URL flavors and URL-shaped titles count as links.
    const explicit_url = [_]BlobView{.{ .ty = "public.url", .data = "https://x" }};
    try std.testing.expectEqual(ContentKind.link, classifyContentKind(&explicit_url, "note"));
    try std.testing.expectEqual(ContentKind.link, classifyContentKind(&[_]BlobView{}, "https://example.com"));

    // Rich-text payloads (HTML/url-name) carrying plain content must NOT be
    // mis-classified as links — that's what put "iOS可上云手机测试。" into the
    // Links tab when copied from a chat app.
    const html_only = [_]BlobView{
        .{ .ty = "public.html", .data = "<p>iOS 可上云手机测试。</p>" },
        .{ .ty = "public.utf8-plain-text", .data = "iOS 可上云手机测试。" },
    };
    try std.testing.expectEqual(ContentKind.text, classifyContentKind(&html_only, "iOS 可上云手机测试。"));

    const url_name_only = [_]BlobView{
        .{ .ty = "public.url-name", .data = "Some Title" },
        .{ .ty = "public.utf8-plain-text", .data = "Some Title" },
    };
    try std.testing.expectEqual(ContentKind.text, classifyContentKind(&url_name_only, "Some Title"));

    const text = [_]BlobView{.{ .ty = "public.utf8-plain-text", .data = "hello" }};
    try std.testing.expectEqual(ContentKind.text, classifyContentKind(&text, "hello"));

    const other = [_]BlobView{.{ .ty = "com.example.binary", .data = "\x00\x01" }};
    try std.testing.expectEqual(ContentKind.other, classifyContentKind(&other, "blob"));
}

test "extractHttpUrl finds link inside html" {
    const html = "<a href=\"https://example.com/docs?q=1\">example</a>";
    const url = extractHttpUrl(html).?;
    try std.testing.expectEqualStrings("https://example.com/docs?q=1", url);
}

test "exec reports sqlite errors" {
    var db = try Db.open(":memory:");
    defer db.close();

    try std.testing.expectError(error.SqliteExecFailed, db.exec("SELECT * FROM missing_table;"));
}

test "insertImported ignores duplicate hashes" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.migrate();

    const blobs = [_]BlobView{.{ .ty = "public.utf8-plain-text", .data = "hello" }};
    const hash = [_]u8{'d'} ** 64;
    try std.testing.expect(try db.insertImported(&blobs, &hash, "title", "app", "", 1, 1, 1, .text));
    try std.testing.expect(!(try db.insertImported(&blobs, &hash, "title", "app", "", 1, 1, 1, .text)));
}

test "insertImported rolls back when content insert cannot be prepared" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec(
        \\CREATE TABLE history_items (
        \\  id INTEGER PRIMARY KEY,
        \\  hash TEXT NOT NULL UNIQUE,
        \\  title TEXT NOT NULL,
        \\  app TEXT,
        \\  first_copied_at INTEGER NOT NULL,
        \\  last_copied_at INTEGER NOT NULL,
        \\  copy_count INTEGER NOT NULL DEFAULT 1,
        \\  content_kind INTEGER NOT NULL DEFAULT 5,
        \\  pin_order INTEGER,
        \\  pin TEXT
        \\);
    );

    const blobs = [_]BlobView{.{ .ty = "public.utf8-plain-text", .data = "hello" }};
    const hash = [_]u8{'r'} ** 64;
    try std.testing.expectError(error.SqlitePrepareFailed, db.insertImported(&blobs, &hash, "title", "app", "", 1, 1, 1, .text));
    try std.testing.expectEqual(@as(i64, 0), try testFetchInt(&db, "SELECT COUNT(*) FROM history_items;"));
}

test "migrate backfills legacy content kind and pin order" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec(
        \\CREATE TABLE history_items (
        \\  id INTEGER PRIMARY KEY,
        \\  hash TEXT NOT NULL UNIQUE,
        \\  title TEXT NOT NULL,
        \\  app TEXT,
        \\  first_copied_at INTEGER NOT NULL,
        \\  last_copied_at INTEGER NOT NULL,
        \\  copy_count INTEGER NOT NULL DEFAULT 1,
        \\  pin TEXT
        \\);
        \\CREATE TABLE history_contents (
        \\  id INTEGER PRIMARY KEY,
        \\  item_id INTEGER NOT NULL REFERENCES history_items(id) ON DELETE CASCADE,
        \\  type TEXT NOT NULL,
        \\  value BLOB NOT NULL
        \\);
        \\INSERT INTO history_items(id, hash, title, app, first_copied_at, last_copied_at, copy_count, pin)
        \\VALUES(1, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'legacy', 'app', 1, 42, 1, 'pinned');
        \\INSERT INTO history_contents(item_id, type, value) VALUES(1, 'public.png', X'89504E47');
    );

    try db.migrate();

    try std.testing.expectEqual(@as(i64, @intFromEnum(ContentKind.image)), try testFetchInt(&db, "SELECT content_kind FROM history_items WHERE id=1;"));
    try std.testing.expectEqual(@as(i64, 42), try testFetchInt(&db, "SELECT pin_order FROM history_items WHERE id=1;"));
}

test "migrate reclassifies html-only legacy rows away from link bucket" {
    // Simulate an existing v1 database that previously bucketed html-bearing
    // rich-text into the Links tab. After migrate() runs against rules v2 the
    // row should land in the Text bucket instead.
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec(
        \\CREATE TABLE history_items (
        \\  id INTEGER PRIMARY KEY,
        \\  hash TEXT NOT NULL UNIQUE,
        \\  title TEXT NOT NULL,
        \\  app TEXT,
        \\  first_copied_at INTEGER NOT NULL,
        \\  last_copied_at INTEGER NOT NULL,
        \\  copy_count INTEGER NOT NULL DEFAULT 1,
        \\  content_kind INTEGER NOT NULL DEFAULT 5,
        \\  pin_order INTEGER,
        \\  pin TEXT
        \\);
        \\CREATE TABLE history_contents (
        \\  id INTEGER PRIMARY KEY,
        \\  item_id INTEGER NOT NULL REFERENCES history_items(id) ON DELETE CASCADE,
        \\  type TEXT NOT NULL,
        \\  value BLOB NOT NULL
        \\);
        \\PRAGMA user_version = 1;
        \\INSERT INTO history_items(id, hash, title, first_copied_at, last_copied_at, copy_count, content_kind)
        \\  VALUES(1, 'h1' || hex(zeroblob(31)), 'iOS 可上云手机测试。', 1, 1, 1, 2);
        \\INSERT INTO history_contents(item_id, type, value) VALUES(1, 'public.html', X'68746D6C');
        \\INSERT INTO history_contents(item_id, type, value) VALUES(1, 'public.utf8-plain-text', X'74657874');
        \\INSERT INTO history_items(id, hash, title, first_copied_at, last_copied_at, copy_count, content_kind)
        \\  VALUES(2, 'h2' || hex(zeroblob(31)), 'https://example.com', 1, 1, 1, 2);
        \\INSERT INTO history_contents(item_id, type, value) VALUES(2, 'public.url', X'68747470733A2F2F6578616D706C652E636F6D');
    );

    try db.migrate();

    try std.testing.expectEqual(
        @as(i64, @intFromEnum(ContentKind.text)),
        try testFetchInt(&db, "SELECT content_kind FROM history_items WHERE id=1;"),
    );
    try std.testing.expectEqual(
        @as(i64, @intFromEnum(ContentKind.link)),
        try testFetchInt(&db, "SELECT content_kind FROM history_items WHERE id=2;"),
    );
    try std.testing.expectEqual(
        @as(i64, 2),
        try testFetchInt(&db, "PRAGMA user_version;"),
    );
}

test "readImagePreview returns first image blob" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.migrate();

    const blobs = [_]BlobView{
        .{ .ty = "public.utf8-plain-text", .data = "note" },
        .{ .ty = "public.jpeg", .data = "jpeg-bytes" },
    };
    const hash = [_]u8{'i'} ** 64;
    try std.testing.expect(try db.insertImported(&blobs, &hash, "image", "app", "", 1, 1, 1, .image));
    const item_id = try testFetchInt(&db, "SELECT id FROM history_items WHERE hash='iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii';");

    const preview = (try db.readImagePreview(item_id, std.testing.allocator)).?;
    defer std.testing.allocator.free(preview);
    try std.testing.expectEqualStrings("jpeg-bytes", preview);
}

test "extractHttpUrl returns null without link" {
    try std.testing.expectEqual(@as(?[]const u8, null), extractHttpUrl("plain text"));
}
