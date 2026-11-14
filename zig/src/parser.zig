//! Phase 1 offline MySQL binlog parser (Zig 0.13, zero dependencies).
//! Emits the canonical JSONL shared by every language implementation.

const std = @import("std");

pub const Error = error{
    Invalid,
    Truncated,
    Checksum,
    NoSchema,
    Unsupported,
};

pub const EventHeader = struct {
    timestamp: u32,
    event_type: u8,
    server_id: u32,
    event_size: u32,
    next_position: u32,
    flags: u16,
};

// ---- CRC-32 (IEEE / zlib), bitwise --------------------------------------
pub fn crc32(data: []const u8) u32 {
    var c: u32 = 0xFFFF_FFFF;
    for (data) |b| {
        c ^= @as(u32, b);
        var k: u8 = 0;
        while (k < 8) : (k += 1) {
            const mask: u32 = 0 -% (c & 1);
            c = (c >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    return ~c;
}

// ---- little-endian read (multiplication avoids shift-width typing) ------
fn leAt(data: []const u8, pos: usize, n: usize) Error!u64 {
    if (n > 8 or pos + n > data.len) return error.Truncated;
    var v: u64 = 0;
    var mul: u64 = 1;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        v += @as(u64, data[pos + i]) * mul;
        if (i + 1 < n) mul *= 256;
    }
    return v;
}

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn rem(self: Reader) usize {
        return if (self.pos >= self.data.len) 0 else self.data.len - self.pos;
    }
    fn le(self: *Reader, n: usize) Error!u64 {
        const v = try leAt(self.data, self.pos, n);
        self.pos += n;
        return v;
    }
    fn raw(self: *Reader, n: usize) Error![]const u8 {
        if (n > self.rem()) return error.Truncated;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
    fn skip(self: *Reader, n: usize) Error!void {
        _ = try self.raw(n);
    }
    fn lenenc(self: *Reader) Error!u64 {
        const b = try self.le(1);
        if (b < 0xFB) return b;
        return switch (b) {
            0xFB => 0,
            0xFC => try self.le(2),
            0xFD => try self.le(3),
            0xFE => try self.le(8),
            else => 0,
        };
    }
};

// ---- Canonical JSON helpers ---------------------------------------------
fn writeJsonStr(w: anytype, s: []const u8) !void {
    const hex = "0123456789abcdef";
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.writeAll("\\u00");
                    try w.writeByte(hex[c >> 4]);
                    try w.writeByte(hex[c & 0x0f]);
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

fn rowsName(t: u8) []const u8 {
    return switch (t) {
        30 => "WRITE_ROWS_EVENT_V2",
        31 => "UPDATE_ROWS_EVENT_V2",
        32 => "DELETE_ROWS_EVENT_V2",
        else => "ROWS_EVENT_V2",
    };
}

// ---- SchemaRegistry -----------------------------------------------------
const Schema = struct {
    table_id: u64,
    db: []const u8,
    table: []const u8,
    cc: usize,
    types: [16]u8 = [_]u8{0} ** 16,
    vlen: [16]u8 = [_]u8{0} ** 16,
    nullable: usize,
};

const Registry = struct {
    items: [16]Schema = undefined,
    count: usize = 0,

    fn put(self: *Registry, s: Schema) void {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.items[i].table_id == s.table_id) {
                self.items[i] = s;
                return;
            }
        }
        if (self.count < self.items.len) {
            self.items[self.count] = s;
            self.count += 1;
        }
    }
    fn get(self: *Registry, id: u64) ?*const Schema {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.items[i].table_id == id) return &self.items[i];
        }
        return null;
    }
};

// ---- Public API ---------------------------------------------------------
pub fn parseHeader(data: []const u8) Error!EventHeader {
    if (data.len < 19) return error.Truncated;
    var r = Reader{ .data = data };
    return EventHeader{
        .timestamp = @intCast(try r.le(4)),
        .event_type = @intCast(try r.le(1)),
        .server_id = @intCast(try r.le(4)),
        .event_size = @intCast(try r.le(4)),
        .next_position = @intCast(try r.le(4)),
        .flags = @intCast(try r.le(2)),
    };
}

pub fn parseBuffer(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len < 4) return error.Invalid;
    if (!(data[0] == 0xFE and data[1] == 'b' and data[2] == 'i' and data[3] == 'n'))
        return error.Invalid;

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    var reg = Registry{};
    var pos: usize = 4; // skip magic
    while (pos < data.len) {
        if (pos + 19 > data.len) return error.Truncated;
        const h = try parseHeader(data[pos .. pos + 19]);
        const es: usize = h.event_size;
        if (es < 23 or pos + es > data.len) return error.Truncated;
        const full = data[pos .. pos + es];
        const stored = try leAt(full, es - 4, 4);
        const calc: u32 = crc32(full[0 .. es - 4]);
        if (stored != @as(u64, calc)) return error.Checksum;
        const body = full[19 .. es - 4];
        var r = Reader{ .data = body };
        const t = h.event_type;
        const ts = h.timestamp;

        switch (t) {
            15 => { // FORMAT_DESCRIPTION_EVENT
                const bv = try r.le(2);
                const tmp = try r.raw(50);
                var k: usize = 0;
                while (k < tmp.len and tmp[k] != 0) : (k += 1) {}
                const alg = body[body.len - 1];
                try w.writeAll("{\"type\":\"FORMAT_DESCRIPTION_EVENT\",\"timestamp\":");
                try w.print("{d}", .{ts});
                try w.writeAll(",\"binlog_version\":");
                try w.print("{d}", .{bv});
                try w.writeAll(",\"server_version\":");
                try writeJsonStr(w, tmp[0..k]);
                try w.writeAll(",\"checksum_alg\":");
                try w.print("{d}", .{alg});
                try w.writeByte('}');
            },
            33 => { // GTID_LOG_EVENT
                _ = try r.le(1); // flags
                const sid = try r.raw(16);
                const gno = try r.le(8);
                const hex = "0123456789abcdef";
                var hexbuf: [32]u8 = undefined;
                for (sid, 0..) |b, i| {
                    hexbuf[2 * i] = hex[b >> 4];
                    hexbuf[2 * i + 1] = hex[b & 0x0f];
                }
                try w.writeAll("{\"type\":\"GTID_LOG_EVENT\",\"timestamp\":");
                try w.print("{d}", .{ts});
                try w.writeAll(",\"gno\":");
                try w.print("{d}", .{gno});
                try w.writeAll(",\"sid\":");
                try writeJsonStr(w, hexbuf[0..]);
                try w.writeByte('}');
            },
            2 => { // QUERY_EVENT
                _ = try r.le(4); // thread_id
                _ = try r.le(4); // exec_time
                const dbl = try r.le(1);
                _ = try r.le(2); // error_code
                const svl = try r.le(2);
                try r.skip(@intCast(svl));
                const db = try r.raw(@intCast(dbl));
                _ = try r.le(1); // trailing NUL
                const query = try r.raw(r.rem());
                try w.writeAll("{\"type\":\"QUERY_EVENT\",\"timestamp\":");
                try w.print("{d}", .{ts});
                try w.writeAll(",\"db\":");
                try writeJsonStr(w, db);
                try w.writeAll(",\"query\":");
                try writeJsonStr(w, query);
                try w.writeByte('}');
            },
            29 => { // ROWS_QUERY_LOG_EVENT
                const ln = try r.lenenc();
                const q = try r.raw(@intCast(ln));
                try w.writeAll("{\"type\":\"ROWS_QUERY_LOG_EVENT\",\"timestamp\":");
                try w.print("{d}", .{ts});
                try w.writeAll(",\"query\":");
                try writeJsonStr(w, q);
                try w.writeByte('}');
            },
            19 => { // TABLE_MAP_EVENT
                const tid = try r.le(6);
                _ = try r.le(2); // flags
                const dbl = try r.le(1);
                const db = try r.raw(@intCast(dbl));
                _ = try r.le(1); // NUL
                const tbl = try r.le(1);
                const table = try r.raw(@intCast(tbl));
                _ = try r.le(1); // NUL
                const cc: usize = @intCast(try r.lenenc());
                var s = Schema{
                    .table_id = tid,
                    .db = db,
                    .table = table,
                    .cc = cc,
                    .nullable = 0,
                };
                var i: usize = 0;
                while (i < cc) : (i += 1) {
                    s.types[i] = @intCast(try r.le(1));
                }
                const mdlen = try r.lenenc();
                const mdstart = r.pos;
                i = 0;
                while (i < cc) : (i += 1) {
                    if (s.types[i] == 15) {
                        const mx = try r.le(2);
                        s.vlen[i] = if (mx > 255) 2 else 1;
                    }
                }
                r.pos = mdstart + @as(usize, @intCast(mdlen));
                const nb = (cc + 7) / 8;
                const nullbm = try r.le(nb);
                var nullable: usize = 0;
                i = 0;
                while (i < cc) : (i += 1) {
                    const bit = @as(u64, 1) << @as(u6, @intCast(i));
                    if (nullbm & bit != 0) nullable += 1;
                }
                s.nullable = nullable;
                reg.put(s);

                try w.writeAll("{\"type\":\"TABLE_MAP_EVENT\",\"timestamp\":");
                try w.print("{d}", .{ts});
                try w.writeAll(",\"table_id\":");
                try w.print("{d}", .{tid});
                try w.writeAll(",\"db\":");
                try writeJsonStr(w, db);
                try w.writeAll(",\"table\":");
                try writeJsonStr(w, table);
                try w.writeAll(",\"column_count\":");
                try w.print("{d}", .{cc});
                try w.writeAll(",\"column_types\":[");
                i = 0;
                while (i < cc) : (i += 1) {
                    if (i > 0) try w.writeByte(',');
                    try w.print("{d}", .{s.types[i]});
                }
                try w.writeAll("]}");
            },
            30, 31, 32 => { // ROWS_EVENT_V2
                const tid = try r.le(6);
                _ = try r.le(2); // flags
                const el = try r.le(2);
                if (el >= 2) try r.skip(@intCast(el - 2));
                const cc: usize = @intCast(try r.lenenc());
                const bm = (cc + 7) / 8;
                const p1 = try r.le(bm);
                if (t == 31) _ = try r.le(bm); // bitmap2, equal
                const s = reg.get(tid) orelse return error.NoSchema;
                const nbs = (s.nullable + 7) / 8;

                try w.writeAll("{\"type\":\"");
                try w.writeAll(rowsName(t));
                try w.writeAll("\",\"timestamp\":");
                try w.print("{d}", .{ts});
                try w.writeAll(",\"table_id\":");
                try w.print("{d}", .{tid});
                try w.writeAll(",\"db\":");
                try writeJsonStr(w, s.db);
                try w.writeAll(",\"table\":");
                try writeJsonStr(w, s.table);
                try w.writeAll(",\"rows\":[");
                var rowno: usize = 0;
                while (r.rem() > 0) {
                    const nullbm = try r.le(nbs);
                    if (rowno > 0) try w.writeByte(',');
                    try w.writeByte('[');
                    var first = true;
                    var i: usize = 0;
                    while (i < s.cc) : (i += 1) {
                        const bit = @as(u64, 1) << @as(u6, @intCast(i));
                        if (p1 & bit == 0) continue;
                        if (!first) try w.writeByte(',');
                        first = false;
                        if (nullbm & bit != 0) {
                            try w.writeAll("null");
                            continue;
                        }
                        const ct = s.types[i];
                        if (ct == 8) {
                            try w.print("{d}", .{try r.le(8)});
                        } else if (ct == 3) {
                            try w.print("{d}", .{try r.le(4)});
                        } else if (ct == 15) {
                            const lb: usize = if (s.vlen[i] == 0) 1 else s.vlen[i];
                            const slen = try r.le(lb);
                            const val = try r.raw(@intCast(slen));
                            try writeJsonStr(w, val);
                        } else return error.Unsupported;
                    }
                    try w.writeByte(']');
                    rowno += 1;
                }
                try w.writeAll("]}");
            },
            16 => { // XID_EVENT
                const xid = try r.le(8);
                try w.writeAll("{\"type\":\"XID_EVENT\",\"timestamp\":");
                try w.print("{d}", .{ts});
                try w.writeAll(",\"xid\":");
                try w.print("{d}", .{xid});
                try w.writeByte('}');
            },
            4 => { // ROTATE_EVENT
                const position = try r.le(8);
                const nf = try r.raw(r.rem());
                try w.writeAll("{\"type\":\"ROTATE_EVENT\",\"timestamp\":");
                try w.print("{d}", .{ts});
                try w.writeAll(",\"position\":");
                try w.print("{d}", .{position});
                try w.writeAll(",\"next_file\":");
                try writeJsonStr(w, nf);
                try w.writeByte('}');
            },
            else => { // UNKNOWN -> safe skip
                try w.writeAll("{\"type\":\"UNKNOWN\",\"timestamp\":");
                try w.print("{d}", .{ts});
                try w.writeAll(",\"type_id\":");
                try w.print("{d}", .{t});
                try w.writeAll(",\"event_size\":");
                try w.print("{d}", .{es});
                try w.writeByte('}');
            },
        }
        try w.writeByte('\n');
        pos += es;
    }
    return out.toOwnedSlice();
}

// ---- Unit + golden tests ------------------------------------------------
test "crc32 vector" {
    try std.testing.expectEqual(@as(u32, 0xCBF4_3926), crc32("123456789"));
}

test "parse header" {
    var h: [19]u8 = [_]u8{0} ** 19;
    h[0] = 0x00;
    h[1] = 0xF1;
    h[2] = 0x53;
    h[3] = 0x65;
    h[4] = 15;
    h[5] = 1;
    h[9] = 119;
    h[13] = 123;
    const out = try parseHeader(&h);
    try std.testing.expectEqual(@as(u32, 1700000000), out.timestamp);
    try std.testing.expectEqual(@as(u8, 15), out.event_type);
    try std.testing.expectEqual(@as(u32, 1), out.server_id);
    try std.testing.expectEqual(@as(u32, 119), out.event_size);
    try std.testing.expectEqual(@as(u32, 123), out.next_position);
    try std.testing.expectEqual(@as(u16, 0), out.flags);
}

test "bad magic" {
    try std.testing.expectError(error.Invalid, parseBuffer(std.testing.allocator, &[_]u8{ 0, 0, 0, 0 }));
}

// End-to-end golden verification for Zig is performed by the CI step
// `diff -u fixtures/expected.jsonl out.jsonl` (same as C / C++ / asm).
// Zig 0.13 forbids @embedFile outside the module package root, so the
// fixture is not embedded here.
