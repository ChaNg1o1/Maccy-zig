const std = @import("std");
const storage = @import("storage.zig");
const c = @cImport({
    @cInclude("macos_clipboard.h");
});

pub const BlobView = storage.BlobView;

pub const CaptureDisposition = enum {
    no_change,
    skipped_empty,
    skipped_self_generated,
    /// Pasteboard carried an org.nspasteboard concealed/transient marker
    /// (password manager copy etc.) — recorded nowhere by design.
    skipped_concealed,
    inserted,
    duplicate_reordered,
};

pub const CaptureResult = struct {
    disposition: CaptureDisposition,
    change_count: i64,
    blob_count: usize,
    has_maccy_marker: bool,
    skipped_type_count: usize,
    skipped_oversize_count: usize,
    skipped_transient_count: usize,
    ordering_changed: bool,
    should_refresh_rows: bool,
    should_prune: bool,
};

pub const CaptureOptions = struct {
    enabled_types: []const []const u8,
    max_blob_bytes: usize,
};

pub fn captureClipboard(allocator: std.mem.Allocator, db: *storage.Db, options: CaptureOptions, last_change: *i64) !CaptureResult {
    const change_count = c.mz_clipboard_change_count();
    if (change_count == last_change.*) {
        return .{
            .disposition = .no_change,
            .change_count = change_count,
            .blob_count = 0,
            .has_maccy_marker = false,
            .skipped_type_count = 0,
            .skipped_oversize_count = 0,
            .skipped_transient_count = 0,
            .ordering_changed = false,
            .should_refresh_rows = false,
            .should_prune = false,
        };
    }

    var snap: c.MZSnapshot = undefined;
    const enabled_c = try makeCStringArray(allocator, options.enabled_types);
    defer freeCStringArray(allocator, enabled_c);
    if (c.mz_clipboard_snapshot(&snap, enabled_c.ptr, enabled_c.len, options.max_blob_bytes) != 0) {
        return error.PasteboardSnapshotFailed;
    }
    defer c.mz_clipboard_snapshot_free(&snap);

    return processSnapshot(allocator, db, &snap, last_change);
}

pub fn processSnapshot(allocator: std.mem.Allocator, db: *storage.Db, snap: *const c.MZSnapshot, last_change: *i64) !CaptureResult {
    if (snap.change_count == last_change.*) {
        return initResult(snap, .no_change);
    }

    if (snap.has_maccy_marker != 0) {
        last_change.* = snap.change_count;
        return initResult(snap, .skipped_self_generated);
    }
    if (snap.has_concealed_marker != 0) {
        last_change.* = snap.change_count;
        return initResult(snap, .skipped_concealed);
    }

    // Persist before consuming the change count: a transient SQLite failure
    // then retries on the next poll tick instead of silently dropping the copy.
    const outcome = try persistSnapshot(allocator, db, snap);
    last_change.* = snap.change_count;

    return switch (outcome) {
        .skipped_empty => initResult(snap, .skipped_empty),
        .inserted => initResult(snap, .inserted),
        .duplicate => initResult(snap, .duplicate_reordered),
    };
}

const PersistDisposition = enum {
    skipped_empty,
    inserted,
    duplicate,
};

fn initResult(snap: *const c.MZSnapshot, disposition: CaptureDisposition) CaptureResult {
    const ordering_changed = disposition == .inserted or disposition == .duplicate_reordered;
    return .{
        .disposition = disposition,
        .change_count = snap.change_count,
        .blob_count = snap.count,
        .has_maccy_marker = snap.has_maccy_marker != 0,
        .skipped_type_count = snap.skipped_type_count,
        .skipped_oversize_count = snap.skipped_oversize_count,
        .skipped_transient_count = snap.skipped_transient_count,
        .ordering_changed = ordering_changed,
        .should_refresh_rows = ordering_changed,
        .should_prune = disposition == .inserted,
    };
}

fn persistSnapshot(allocator: std.mem.Allocator, db: *storage.Db, snap: *const c.MZSnapshot) !PersistDisposition {
    if (snap.count == 0) return .skipped_empty;

    var views = try allocator.alloc(BlobView, snap.count);
    defer allocator.free(views);

    var valid: usize = 0;
    for (0..snap.count) |i| {
        const blob = snap.blobs[i];
        if (blob.type == null or blob.data == null or blob.len == 0) continue;
        views[valid] = .{
            .ty = std.mem.span(blob.type),
            .data = blob.data[0..blob.len],
        };
        valid += 1;
    }
    if (valid == 0) return .skipped_empty;

    const hash_hex = computeHashHex(views[0..valid]);
    const title_buf = titleFromBlobs(views[0..valid]);
    const title = std.mem.sliceTo(title_buf[0..], 0);
    const content_kind = storage.classifyContentKind(views[0..valid], title);
    const app = if (snap.source_bundle != null) std.mem.span(snap.source_bundle) else "";
    return switch (try db.upsertCapture(views[0..valid], &hash_hex, &title_buf, app, content_kind)) {
        .inserted => .inserted,
        .duplicate => .duplicate,
    };
}

pub fn makeCStringArray(allocator: std.mem.Allocator, values: []const []const u8) ![][*c]const u8 {
    var out = try allocator.alloc([*c]const u8, values.len);
    errdefer allocator.free(out);
    var built: usize = 0;
    errdefer for (out[0..built]) |value| allocator.free(@constCast(std.mem.span(value)));
    for (values, 0..) |value, idx| {
        out[idx] = (try allocator.dupeZ(u8, value)).ptr;
        built += 1;
    }
    return out;
}

pub fn freeCStringArray(allocator: std.mem.Allocator, values: [][*c]const u8) void {
    for (values) |value| allocator.free(@constCast(std.mem.span(value)));
    allocator.free(values);
}

pub fn computeHashHex(blobs: []const BlobView) [64]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (blobs) |blob| {
        h.update(blob.ty);
        h.update(&[_]u8{0});
        h.update(blob.data);
        h.update(&[_]u8{0xff});
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return hexLower(&digest);
}

fn hexLower(bytes: []const u8) [64]u8 {
    const alphabet = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (bytes, 0..) |b, i| {
        out[i * 2] = alphabet[b >> 4];
        out[i * 2 + 1] = alphabet[b & 0x0f];
    }
    return out;
}

pub fn titleFromBlobs(blobs: []const BlobView) [256]u8 {
    var out: [256]u8 = [_]u8{0} ** 256;
    if (titleFromTextBlob(blobs, "public.utf8-plain-text", &out)) return out;
    // No plain text: URL flavors are still human-readable strings, far more
    // useful in the list than a "[data]" placeholder.
    if (titleFromTextBlob(blobs, "public.url-name", &out)) return out;
    if (titleFromTextBlob(blobs, "public.url", &out)) return out;
    if (titleFromTextBlob(blobs, "public.file-url", &out)) return out;
    for (blobs) |blob| {
        if (std.mem.indexOf(u8, blob.ty, "png") != null or
            std.mem.indexOf(u8, blob.ty, "tiff") != null or
            std.mem.indexOf(u8, blob.ty, "jpeg") != null or
            std.mem.indexOf(u8, blob.ty, "heic") != null)
        {
            @memcpy(out[0..7], "[image]");
            return out;
        }
    }
    @memcpy(out[0..6], "[data]");
    return out;
}

fn titleFromTextBlob(blobs: []const BlobView, ty: []const u8, out: *[256]u8) bool {
    for (blobs) |blob| {
        if (!std.mem.eql(u8, blob.ty, ty)) continue;
        const prefix = utf8SafePrefix(blob.data, out.len - 1);
        if (prefix.len == 0) {
            if (std.mem.eql(u8, ty, "public.utf8-plain-text")) {
                @memcpy(out[0..6], "[text]");
                return true;
            }
            continue;
        }
        @memcpy(out[0..prefix.len], prefix);
        sanitizeTitle(out[0..prefix.len]);
        return true;
    }
    return false;
}

fn utf8SafePrefix(bytes: []const u8, max_len: usize) []const u8 {
    var end = @min(bytes.len, max_len);
    while (end > 0 and !std.unicode.utf8ValidateSlice(bytes[0..end])) : (end -= 1) {}
    return bytes[0..end];
}

pub fn sanitizeTitle(bytes: []u8) void {
    for (bytes) |*b| {
        if (b.* == '\n') b.* = ' ';
        if (b.* == '\t') b.* = ' ';
        if (b.* == 0) b.* = ' ';
    }
}

test "processSnapshot skips concealed pasteboard entirely" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();

    var ty_buf = "public.utf8-plain-text".*;
    var data_buf = "hunter2-secret".*;
    var blob = c.MZBlob{ .type = &ty_buf, .data = &data_buf, .len = data_buf.len };
    var snap = std.mem.zeroes(c.MZSnapshot);
    snap.change_count = 7;
    snap.count = 1;
    snap.blobs = &blob;
    snap.has_concealed_marker = 1;

    var last_change: i64 = -1;
    const result = try processSnapshot(std.testing.allocator, &db, &snap, &last_change);
    try std.testing.expectEqual(CaptureDisposition.skipped_concealed, result.disposition);
    // Marker consumed the change so we don't re-inspect it every poll tick...
    try std.testing.expectEqual(@as(i64, 7), last_change);
    // ...but nothing was persisted.
    const stmt = try db.prepare("SELECT COUNT(*) FROM history_items;");
    defer _ = storage.sqlite.sqlite3_finalize(stmt);
    try std.testing.expect(storage.sqlite.sqlite3_step(stmt) == storage.sqlite.SQLITE_ROW);
    try std.testing.expectEqual(@as(i64, 0), storage.sqlite.sqlite3_column_int64(stmt, 0));
}

test "processSnapshot keeps last_change unconsumed when persist fails" {
    // No migrate(): the insert will fail against the missing table.
    var db = try storage.Db.open(":memory:");
    defer db.close();

    var ty_buf = "public.utf8-plain-text".*;
    var data_buf = "payload".*;
    var blob = c.MZBlob{ .type = &ty_buf, .data = &data_buf, .len = data_buf.len };
    var snap = std.mem.zeroes(c.MZSnapshot);
    snap.change_count = 3;
    snap.count = 1;
    snap.blobs = &blob;

    var last_change: i64 = -1;
    try std.testing.expectError(error.SqlitePrepareFailed, processSnapshot(std.testing.allocator, &db, &snap, &last_change));
    // The change stays pending so the next poll retries instead of dropping it.
    try std.testing.expectEqual(@as(i64, -1), last_change);
}

test "titleFromBlobs uses url flavors before falling back to [data]" {
    const url_only = [_]BlobView{.{ .ty = "public.url", .data = "https://example.com/a" }};
    try std.testing.expectEqualStrings(
        "https://example.com/a",
        std.mem.sliceTo(&titleFromBlobs(&url_only), 0),
    );

    const file_only = [_]BlobView{.{ .ty = "public.file-url", .data = "file:///tmp/report.pdf" }};
    try std.testing.expectEqualStrings(
        "file:///tmp/report.pdf",
        std.mem.sliceTo(&titleFromBlobs(&file_only), 0),
    );

    const jpeg_only = [_]BlobView{.{ .ty = "public.jpeg", .data = "\xff\xd8" }};
    try std.testing.expectEqualStrings("[image]", std.mem.sliceTo(&titleFromBlobs(&jpeg_only), 0));
}

test "titleFromBlobs keeps long utf8 text decodable" {
    const chunk = "你好";
    const long_text = chunk ** 120;
    const blobs = [_]BlobView{.{ .ty = "public.utf8-plain-text", .data = long_text }};
    const title = titleFromBlobs(&blobs);
    const slice = std.mem.sliceTo(title[0..], 0);
    try std.testing.expect(slice.len > 0);
    try std.testing.expect(std.unicode.utf8ValidateSlice(slice));
}

test "titleFromBlobs falls back for invalid text image and data" {
    const invalid_text = [_]BlobView{.{ .ty = "public.utf8-plain-text", .data = "\xff" }};
    const text_title = titleFromBlobs(&invalid_text);
    try std.testing.expectEqualStrings("[text]", std.mem.sliceTo(text_title[0..], 0));

    const image = [_]BlobView{.{ .ty = "public.tiff", .data = "image" }};
    const image_title = titleFromBlobs(&image);
    try std.testing.expectEqualStrings("[image]", std.mem.sliceTo(image_title[0..], 0));

    const data = [_]BlobView{.{ .ty = "com.example.binary", .data = "data" }};
    const data_title = titleFromBlobs(&data);
    try std.testing.expectEqualStrings("[data]", std.mem.sliceTo(data_title[0..], 0));
}
