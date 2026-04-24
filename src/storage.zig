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

pub const Db = struct {
    handle: *sqlite.sqlite3,
    const pinned_marker = "pinned";

    pub const UpsertOutcome = enum {
        inserted,
        duplicate,
    };

    pub fn open(path: []const u8) !Db {
        var db: ?*sqlite.sqlite3 = null;
        const zpath = try std.heap.page_allocator.dupeZ(u8, path);
        defer std.heap.page_allocator.free(zpath);
        if (sqlite.sqlite3_open(zpath.ptr, &db) != sqlite.SQLITE_OK) return error.SqliteOpenFailed;
        return .{ .handle = db.? };
    }

    pub fn close(self: *Db) void {
        _ = sqlite.sqlite3_close(self.handle);
    }

    pub fn migrate(self: *Db) !void {
        try self.exec(
            \\PRAGMA journal_mode=WAL;
            \\PRAGMA synchronous=NORMAL;
            \\PRAGMA foreign_keys=ON;
            \\CREATE TABLE IF NOT EXISTS history_items (
            \\  id INTEGER PRIMARY KEY,
            \\  hash TEXT NOT NULL UNIQUE,
            \\  title TEXT NOT NULL,
            \\  app TEXT,
            \\  first_copied_at INTEGER NOT NULL,
            \\  last_copied_at INTEGER NOT NULL,
            \\  copy_count INTEGER NOT NULL DEFAULT 1,
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
        );
    }

    pub fn exec(self: *Db, sql: [:0]const u8) !void {
        var err: [*c]u8 = null;
        if (sqlite.sqlite3_exec(self.handle, sql.ptr, null, null, &err) != sqlite.SQLITE_OK) {
            if (err != null) sqlite.sqlite3_free(err);
            return error.SqliteExecFailed;
        }
    }

    pub fn upsertCapture(self: *Db, blobs: []const BlobView, hash_hex: *const [64]u8, title_buf: *const [256]u8, app: []const u8) !UpsertOutcome {
        const now: i64 = @intCast(c.time(null));
        if (try self.updateDuplicate(hash_hex, now)) return .duplicate;

        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};

        const stmt = try self.prepare("INSERT INTO history_items(hash,title,app,first_copied_at,last_copied_at,copy_count) VALUES(?1,?2,?3,?4,?5,1);");
        defer _ = sqlite.sqlite3_finalize(stmt);
        try bindText(stmt, 1, hash_hex[0..]);
        try bindText(stmt, 2, std.mem.sliceTo(title_buf, 0));
        try bindText(stmt, 3, app);
        _ = sqlite.sqlite3_bind_int64(stmt, 4, now);
        _ = sqlite.sqlite3_bind_int64(stmt, 5, now);
        try stepDone(stmt);

        const item_id = sqlite.sqlite3_last_insert_rowid(self.handle);
        for (blobs) |blob| {
            const cstmt = try self.prepare("INSERT INTO history_contents(item_id,type,value) VALUES(?1,?2,?3);");
            defer _ = sqlite.sqlite3_finalize(cstmt);
            _ = sqlite.sqlite3_bind_int64(cstmt, 1, item_id);
            try bindText(cstmt, 2, blob.ty);
            try bindBlob(cstmt, 3, blob.data);
            try stepDone(cstmt);
        }
        try self.exec("COMMIT;");
        return .inserted;
    }

    pub fn insertImported(self: *Db, blobs: []const BlobView, hash_hex: *const [64]u8, title: []const u8, app: []const u8, pin: []const u8, first_ts: i64, last_ts: i64, copy_count: i64) !bool {
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};
        const stmt = try self.prepare("INSERT OR IGNORE INTO history_items(hash,title,app,first_copied_at,last_copied_at,copy_count,pin) VALUES(?1,?2,?3,?4,?5,?6,NULLIF(?7,''));");
        defer _ = sqlite.sqlite3_finalize(stmt);
        try bindText(stmt, 1, hash_hex[0..]);
        try bindText(stmt, 2, title);
        try bindText(stmt, 3, app);
        _ = sqlite.sqlite3_bind_int64(stmt, 4, first_ts);
        _ = sqlite.sqlite3_bind_int64(stmt, 5, last_ts);
        _ = sqlite.sqlite3_bind_int64(stmt, 6, if (copy_count <= 0) 1 else copy_count);
        try bindText(stmt, 7, pin);
        try stepDone(stmt);
        if (sqlite.sqlite3_changes(self.handle) == 0) {
            try self.exec("COMMIT;");
            return false;
        }
        const item_id = sqlite.sqlite3_last_insert_rowid(self.handle);
        for (blobs) |blob| {
            const cstmt = try self.prepare("INSERT INTO history_contents(item_id,type,value) VALUES(?1,?2,?3);");
            defer _ = sqlite.sqlite3_finalize(cstmt);
            _ = sqlite.sqlite3_bind_int64(cstmt, 1, item_id);
            try bindText(cstmt, 2, blob.ty);
            try bindBlob(cstmt, 3, blob.data);
            try stepDone(cstmt);
        }
        try self.exec("COMMIT;");
        return true;
    }

    fn updateDuplicate(self: *Db, hash_hex: *const [64]u8, now: i64) !bool {
        const stmt = try self.prepare("UPDATE history_items SET last_copied_at=?1, copy_count=copy_count+1 WHERE hash=?2;");
        defer _ = sqlite.sqlite3_finalize(stmt);
        _ = sqlite.sqlite3_bind_int64(stmt, 1, now);
        try bindText(stmt, 2, hash_hex[0..]);
        try stepDone(stmt);
        return sqlite.sqlite3_changes(self.handle) > 0;
    }

    pub fn prune(self: *Db, max_items: i64) !void {
        const stmt = try self.prepare(
            \\DELETE FROM history_items
            \\WHERE pin IS NULL AND id IN (
            \\  SELECT id FROM history_items WHERE pin IS NULL
            \\  ORDER BY last_copied_at DESC LIMIT -1 OFFSET ?1
            \\);
        );
        defer _ = sqlite.sqlite3_finalize(stmt);
        _ = sqlite.sqlite3_bind_int64(stmt, 1, max_items);
        try stepDone(stmt);
    }

    pub fn clearAll(self: *Db) !void {
        try self.exec("DELETE FROM history_items;");
    }

    pub fn clearUnpinned(self: *Db) !void {
        try self.exec("DELETE FROM history_items WHERE pin IS NULL;");
    }

    pub fn togglePin(self: *Db, id: i64) !bool {
        const stmt = try self.prepare("UPDATE history_items SET pin = CASE WHEN pin IS NULL THEN ?1 ELSE NULL END WHERE id=?2;");
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
        while (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            const ty_raw = sqlite.sqlite3_column_text(stmt, 0) orelse continue;
            const ty = std.mem.span(ty_raw);
            if (plain_only and !(std.mem.eql(u8, ty, "public.utf8-plain-text") or std.mem.eql(u8, ty, "public.file-url"))) continue;
            const len_i = sqlite.sqlite3_column_bytes(stmt, 1);
            if (len_i <= 0) continue;
            const blob_ptr = sqlite.sqlite3_column_blob(stmt, 1) orelse continue;
            const len: usize = @intCast(len_i);
            const bytes = @as([*]const u8, @ptrCast(blob_ptr))[0..len];
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

    pub fn prepare(self: *Db, sql: [:0]const u8) !*sqlite.sqlite3_stmt {
        var stmt: ?*sqlite.sqlite3_stmt = null;
        if (sqlite.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != sqlite.SQLITE_OK) return error.SqlitePrepareFailed;
        return stmt.?;
    }
};

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

test "togglePin stores stable marker and null" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.migrate();

    const blobs = [_]BlobView{.{ .ty = "public.utf8-plain-text", .data = "hello" }};
    const hash = [_]u8{'a'} ** 64;
    try std.testing.expect(try db.insertImported(&blobs, &hash, "title", "app", "", 1, 1, 1));

    const item_id = sqlite.sqlite3_last_insert_rowid(db.handle);
    try std.testing.expectEqual(@as(i64, 1), item_id);
    try std.testing.expectEqual(@as(?[]u8, null), try testFetchPin(&db, item_id, std.testing.allocator));

    try std.testing.expect(try db.togglePin(item_id));
    const pinned = (try testFetchPin(&db, item_id, std.testing.allocator)).?;
    defer std.testing.allocator.free(pinned);
    try std.testing.expectEqualStrings(Db.pinned_marker, pinned);

    try std.testing.expect(try db.togglePin(item_id));
    try std.testing.expectEqual(@as(?[]u8, null), try testFetchPin(&db, item_id, std.testing.allocator));
}

test "togglePin returns false for missing row" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.migrate();

    try std.testing.expect(!(try db.togglePin(99)));
}
