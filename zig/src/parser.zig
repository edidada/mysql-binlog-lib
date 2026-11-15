//! Phase 1 offline MySQL binlog parser (Zig 0.13, zero dependencies).
//! Emits the canonical JSONL shared by every language implementation.
//!
//! Layered structure (mirrors c/src/mysqlbinlog.c and docs/design.md section 4):
//!
//!   [1] ByteReader     bounds-checked little-endian primitives
//!   [2] CRC-32         IEEE / zlib checksum
//!   [3] Serializer     canonical JSONL builder (fixed key order, no spaces)
//!   [4] SchemaRegistry table_id -> TableSchema
//!   [5] RowDecoder     decode RowsEventV2 rows using a registered schema
//!   [6] EventParser    frame/verify/dispatch events -> one JSONL line each
//!   [7] Public API     parseHeader / crc32 / parseBuffer
//!
//! The public API and the canonical JSONL are a cross-language contract shared
//! by the other nine implementations and fixtures/expected.jsonl.

const std = @import("std");

// ==================================================================
// [0] Protocol constants (docs/design.md sections 2-3).
// ==================================================================
const MAGIC = [_]u8{ 0xFE, 'b', 'i', 'n' };
const HEADER_SIZE = 19;
const CRC_SIZE = 4;
const MAGIC_SIZE = 4;

const MAX_COLS = 64;
const MAX_TABLES = 64;
const MAX_EVENT_SIZE = 256 * 1024 * 1024; // corrupt-size guard
const LINE_CAP = 16384;                   // max single JSONL line
const STR_CAP = 2048;                     // max query / next_file string
const VALUE_CAP = 512;                    // max VARCHAR value
const NAME_CAP = 128;                     // max db / table name
const SERVER_VERSION_LEN = 50;

const TYPE_LONG = 3;
const TYPE_LONGLONG = 8;
const TYPE_VARCHAR = 15;

const EV_QUERY = 2;
const EV_ROTATE = 4;
const EV_FORMAT_DESC = 15;
const EV_XID = 16;
const EV_TABLE_MAP = 19;
const EV_ROWS_QUERY = 29;
const EV_WRITE_ROWS_V2 = 30;
const EV_UPDATE_ROWS_V2 = 31;
const EV_DELETE_ROWS_V2 = 32;
const EV_GTID = 33;

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

// ==================================================================
// [1] ByteReader: every read is bounds-checked; `err` latches.
// ==================================================================
const ByteReader = struct {
    data: []const u8,
    pos: usize = 0,
    err: ?Error = null, // first failure, latched

    fn len(self: ByteReader) usize { return self.data.len; }

    fn rem(self: ByteReader) usize {
        return if (self.pos >= self.data.len) 0 else self.data.len - self.pos;
    }

    /// Overflow-safe `pos + n <= len` test.
    fn can(self: ByteReader, n: usize) bool {
        return self.err == null and n <= self.data.len and self.pos <= self.data.len - n;
    }

    fn fail(self: *ByteReader, e: Error) void {
        if (self.err == null) self.err = e;
    }

    /// Little-endian read of n bytes (n <= 8).
    fn le(self: *ByteReader, n: usize) u64 {
        if (n > 8 or !self.can(n)) {
            self.fail(error.Truncated);
            return 0;
        }
        var v: u64 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            v |= @as(u64, self.data[self.pos + i]) << @as(u6, @intCast(8 * i));
        }
        self.pos += n;
        return v;
    }

    fn raw(self: *ByteReader, n: usize) []const u8 {
        if (!self.can(n)) {
            self.fail(error.Truncated);
            return &[_]u8{};
        }
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    /// Read exactly n bytes as a bounded string but always advance by n,
    /// so framing stays aligned (mirrors rd_strn in the C reference).
    fn strn(self: *ByteReader, n: usize, cap: usize) []const u8 {
        if (cap == 0) return &[_]u8{};
        if (!self.can(n)) {
            self.fail(error.Truncated);
            return &[_]u8{};
        }
        const m = @min(n, cap - 1);
        const s = self.data[self.pos .. self.pos + m];
        self.pos += n;
        return s;
    }

    fn skip(self: *ByteReader, n: usize) void {
        if (!self.can(n)) {
            self.fail(error.Truncated);
            return;
        }
        self.pos += n;
    }

    /// MySQL length-encoded integer. 0xFB (NULL) and 0xFF (reserved) are not
    /// valid lengths where a length is required.
    fn lenenc(self: *ByteReader) u64 {
        const b = self.le(1);
        if (self.err != null) return 0;
        if (b < 0xFB) return b;
        if (b == 0xFC) return self.le(2);
        if (b == 0xFD) return self.le(3);
        if (b == 0xFE) return self.le(8);
        self.fail(error.Unsupported);
        return 0;
    }

    fn lastByte(self: ByteReader) u8 {
        return if (self.data.len == 0) 0 else self.data[self.data.len - 1];
    }

    fn setPos(self: *ByteReader, n: usize) void { self.pos = n; }

    fn require(self: ByteReader) Error!void {
        if (self.err) |e| return e;
    }
};

fn peekLe(data: []const u8, off: usize, n: usize) Error!u64 {
    if (n > 8 or off > data.len or n > data.len - off) return error.Truncated;
    var v: u64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        v |= @as(u64, data[off + i]) << @as(u6, @intCast(8 * i));
    }
    return v;
}

// ==================================================================
// [2] CRC-32 (IEEE 802.3 / zlib).
// Vector: crc32("123456789") == 0xCBF43926.
// ==================================================================
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

// ==================================================================
// [3] Serializer: bounded canonical JSONL builder.
// ==================================================================
const Serializer = struct {
    list: std.ArrayList(u8),
    cap: usize,
    overflow: bool = false,

    fn init(allocator: std.mem.Allocator, cap: usize) Serializer {
        return .{ .list = std.ArrayList(u8).init(allocator), .cap = cap };
    }

    fn deinit(self: *Serializer) void { self.list.deinit(); }

    fn append(self: *Serializer, s: []const u8) !void {
        if (self.overflow) return;
        if (self.list.items.len + s.len > self.cap) {
            self.overflow = true;
            return;
        }
        try self.list.appendSlice(s);
    }

    fn putc(self: *Serializer, c: u8) !void {
        var one = [1]u8{c};
        try self.append(one[0..]);
    }

    fn puts(self: *Serializer, s: []const u8) !void { try self.append(s); }

    fn uint(self: *Serializer, v: anytype) !void {
        var tmp: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
        try self.append(s);
    }

    /// Minimal JSON escaping: quotes, backslash, control characters.
    fn jsonStr(self: *Serializer, s: []const u8) !void {
        const hex = "0123456789abcdef";
        try self.putc('"');
        for (s) |c| {
            switch (c) {
                '"' => try self.puts("\\\""),
                '\\' => try self.puts("\\\\"),
                '\n' => try self.puts("\\n"),
                '\r' => try self.puts("\\r"),
                '\t' => try self.puts("\\t"),
                else => {
                    if (c < 0x20) {
                        try self.puts("\\u00");
                        try self.putc(hex[c >> 4]);
                        try self.putc(hex[c & 0x0f]);
                    } else {
                        try self.putc(c);
                    }
                },
            }
        }
        try self.putc('"');
    }

    fn finish(self: Serializer) Error![]const u8 {
        if (self.overflow) return error.Invalid;
        return self.list.items;
    }
};

fn bit(v: u64, i: usize) bool {
    return (v & (@as(u64, 1) << @as(u6, @intCast(i)))) != 0;
}

// ==================================================================
// [4] SchemaRegistry: table_id -> TableSchema, per-file lifetime.
// ==================================================================
const TableSchema = struct {
    table_id: u64,
    db: []const u8,
    table: []const u8,
    column_count: usize,
    column_types: [MAX_COLS]u8 = [_]u8{0} ** MAX_COLS,
    varchar_len_bytes: [MAX_COLS]u8 = [_]u8{0} ** MAX_COLS,
    nullable_count: usize,
};

const Registry = struct {
    items: [MAX_TABLES]TableSchema = undefined,
    count: usize = 0,

    fn put(self: *Registry, s: TableSchema) void {
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

    fn get(self: *Registry, id: u64) ?*const TableSchema {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.items[i].table_id == id) return &self.items[i];
        }
        return null;
    }
};

// ==================================================================
// [5] RowDecoder: decode a row sequence against a TableSchema.
// ==================================================================
fn decodeValue(r: *ByteReader, s: *const TableSchema, col: usize,
               is_null: bool, b: *Serializer) !void {
    if (is_null) {
        try b.puts("null");
        return;
    }
    switch (s.column_types[col]) {
        TYPE_LONGLONG => {
            const v = r.le(8);
            try b.uint(@as(i64, @bitCast(v)));
        },
        TYPE_LONG => {
            const v = r.le(4);
            const u: u32 = @truncate(v);
            try b.uint(@as(i32, @bitCast(u)));
        },
        TYPE_VARCHAR => {
            const lb: usize = s.varchar_len_bytes[col];
            if (lb != 1 and lb != 2) return error.Unsupported;
            const slen: usize = @intCast(r.le(lb));
            try r.require();
            if (slen > VALUE_CAP - 1) return error.Unsupported;
            try b.jsonStr(r.strn(slen, VALUE_CAP));
        },
        else => return error.Unsupported,
    }
    try r.require();
}

fn decodeRows(r: *ByteReader, s: *const TableSchema, present: u64,
              b: *Serializer) !void {
    const nb_size = (s.nullable_count + 7) / 8;
    if (nb_size > 8) return error.Unsupported;
    try b.puts(",\"rows\":[");
    var rowno: usize = 0;
    while (r.rem() > 0 and r.err == null) {
        const nullbm = r.le(nb_size);
        try r.require();
        if (rowno > 0) try b.putc(',');
        try b.putc('[');
        var first = true;
        var i: usize = 0;
        while (i < s.column_count) : (i += 1) {
            if (!bit(present, i)) continue;
            if (!first) try b.putc(',');
            first = false;
            try decodeValue(r, s, i, bit(nullbm, i), b);
        }
        try b.putc(']');
        rowno += 1;
    }
    try b.puts("]}");
    try r.require();
}

// ==================================================================
// [6] EventParser: header, framing, per-event dispatch.
// ==================================================================
pub fn parseHeader(data: []const u8) Error!EventHeader {
    if (data.len < HEADER_SIZE) return error.Truncated;
    var r = ByteReader{ .data = data[0..HEADER_SIZE] };
    const h = EventHeader{
        .timestamp = @truncate(r.le(4)),
        .event_type = @truncate(r.le(1)),
        .server_id = @truncate(r.le(4)),
        .event_size = @truncate(r.le(4)),
        .next_position = @truncate(r.le(4)),
        .flags = @truncate(r.le(2)),
    };
    try r.require();
    return h;
}

fn rowsName(t: u8) []const u8 {
    return switch (t) {
        EV_WRITE_ROWS_V2 => "WRITE_ROWS_EVENT_V2",
        EV_UPDATE_ROWS_V2 => "UPDATE_ROWS_EVENT_V2",
        EV_DELETE_ROWS_V2 => "DELETE_ROWS_EVENT_V2",
        else => "ROWS_EVENT_V2",
    };
}

fn parseFde(r: *ByteReader, h: EventHeader, b: *Serializer) !void {
    if (r.rem() < 2 + SERVER_VERSION_LEN + 1) return error.Truncated;
    const bv = r.le(2);
    const tmp = r.raw(SERVER_VERSION_LEN);
    const alg = r.lastByte();
    try r.require();
    var k: usize = 0;
    while (k < tmp.len and tmp[k] != 0) : (k += 1) {}
    try b.puts("{\"type\":\"FORMAT_DESCRIPTION_EVENT\",\"timestamp\":");
    try b.uint(h.timestamp);
    try b.puts(",\"binlog_version\":");
    try b.uint(bv);
    try b.puts(",\"server_version\":");
    try b.jsonStr(tmp[0..k]);
    try b.puts(",\"checksum_alg\":");
    try b.uint(alg);
    try b.putc('}');
}

fn parseGtid(r: *ByteReader, h: EventHeader, b: *Serializer) !void {
    _ = r.le(1); // flags
    const sid = r.raw(16);
    const gno = r.le(8);
    try r.require();
    const hex = "0123456789abcdef";
    var hexbuf: [32]u8 = undefined;
    for (sid, 0..) |x, i| {
        hexbuf[2 * i] = hex[x >> 4];
        hexbuf[2 * i + 1] = hex[x & 0x0f];
    }
    try b.puts("{\"type\":\"GTID_LOG_EVENT\",\"timestamp\":");
    try b.uint(h.timestamp);
    try b.puts(",\"gno\":");
    try b.uint(gno);
    try b.puts(",\"sid\":");
    try b.jsonStr(hexbuf[0..]);
    try b.putc('}');
}

fn parseQuery(r: *ByteReader, h: EventHeader, b: *Serializer) !void {
    _ = r.le(4); // thread_id
    _ = r.le(4); // exec_time
    const dbl: usize = @intCast(r.le(1));
    _ = r.le(2); // error_code
    const svl: usize = @intCast(r.le(2));
    r.skip(svl); // status_vars
    const db = r.strn(dbl, NAME_CAP);
    _ = r.le(1); // trailing NUL after db
    const query_len = r.rem();
    const query = r.strn(query_len, STR_CAP);
    try r.require();
    try b.puts("{\"type\":\"QUERY_EVENT\",\"timestamp\":");
    try b.uint(h.timestamp);
    try b.puts(",\"db\":");
    try b.jsonStr(db);
    try b.puts(",\"query\":");
    try b.jsonStr(query);
    try b.putc('}');
}

fn parseRowsQuery(r: *ByteReader, h: EventHeader, b: *Serializer) !void {
    const ln: usize = @intCast(r.lenenc());
    const q = r.strn(ln, STR_CAP);
    try r.require();
    try b.puts("{\"type\":\"ROWS_QUERY_LOG_EVENT\",\"timestamp\":");
    try b.uint(h.timestamp);
    try b.puts(",\"query\":");
    try b.jsonStr(q);
    try b.putc('}');
}

fn parseTableMap(r: *ByteReader, h: EventHeader, reg: *Registry,
                 b: *Serializer) !void {
    var s = TableSchema{
        .table_id = r.le(6),
        .db = &[_]u8{},
        .table = &[_]u8{},
        .column_count = 0,
        .nullable_count = 0,
    };
    _ = r.le(2); // flags
    const dbl: usize = @intCast(r.le(1));
    s.db = r.strn(dbl, NAME_CAP);
    _ = r.le(1); // NUL
    const tbl: usize = @intCast(r.le(1));
    s.table = r.strn(tbl, NAME_CAP);
    _ = r.le(1); // NUL
    const cc: usize = @intCast(r.lenenc());
    try r.require();
    if (cc == 0 or cc > MAX_COLS) return error.Unsupported;
    s.column_count = cc;
    var i: usize = 0;
    while (i < cc) : (i += 1) s.column_types[i] = @truncate(r.le(1));

    const md_len: usize = @intCast(r.lenenc());
    const md_start = r.pos;
    if (r.err != null or md_len > r.len() or md_start > r.len() - md_len)
        return error.Truncated;
    i = 0;
    while (i < cc) : (i += 1) {
        if (s.column_types[i] == TYPE_VARCHAR) {
            if (r.pos + 2 > md_start + md_len) return error.Truncated;
            const mx = r.le(2);
            s.varchar_len_bytes[i] = if (mx > 255) 2 else 1;
        }
    }
    r.setPos(md_start + md_len); // skip any extra metadata

    const nb = (cc + 7) / 8;
    if (nb > 8) return error.Unsupported;
    const nullbm = r.le(nb);
    var nullable: usize = 0;
    i = 0;
    while (i < cc) : (i += 1) {
        if (bit(nullbm, i)) nullable += 1;
    }
    s.nullable_count = nullable;
    try r.require();
    reg.put(s);

    try b.puts("{\"type\":\"TABLE_MAP_EVENT\",\"timestamp\":");
    try b.uint(h.timestamp);
    try b.puts(",\"table_id\":");
    try b.uint(s.table_id);
    try b.puts(",\"db\":");
    try b.jsonStr(s.db);
    try b.puts(",\"table\":");
    try b.jsonStr(s.table);
    try b.puts(",\"column_count\":");
    try b.uint(cc);
    try b.puts(",\"column_types\":[");
    i = 0;
    while (i < cc) : (i += 1) {
        if (i > 0) try b.putc(',');
        try b.uint(s.column_types[i]);
    }
    try b.puts("]}");
}

fn parseRowsV2(r: *ByteReader, h: EventHeader, reg: *Registry,
               b: *Serializer) !void {
    const tid = r.le(6);
    _ = r.le(2); // flags
    const extra_len: usize = @intCast(r.le(2)); // includes its own 2 bytes
    if (extra_len < 2) return error.Unsupported;
    r.skip(extra_len - 2);
    const cc: usize = @intCast(r.lenenc());
    try r.require();
    if (cc == 0 or cc > MAX_COLS) return error.Unsupported;
    const bm_size = (cc + 7) / 8;
    if (bm_size > 8) return error.Unsupported;
    const present = r.le(bm_size);
    if (h.event_type == EV_UPDATE_ROWS_V2) _ = r.le(bm_size); // before/after bitmap
    try r.require();
    const s = reg.get(tid) orelse return error.NoSchema;

    try b.puts("{\"type\":\"");
    try b.puts(rowsName(h.event_type));
    try b.puts("\",\"timestamp\":");
    try b.uint(h.timestamp);
    try b.puts(",\"table_id\":");
    try b.uint(tid);
    try b.puts(",\"db\":");
    try b.jsonStr(s.db);
    try b.puts(",\"table\":");
    try b.jsonStr(s.table);
    try decodeRows(r, s, present, b);
}

fn parseXid(r: *ByteReader, h: EventHeader, b: *Serializer) !void {
    const xid = r.le(8);
    try r.require();
    try b.puts("{\"type\":\"XID_EVENT\",\"timestamp\":");
    try b.uint(h.timestamp);
    try b.puts(",\"xid\":");
    try b.uint(xid);
    try b.putc('}');
}

fn parseRotate(r: *ByteReader, h: EventHeader, b: *Serializer) !void {
    const position = r.le(8);
    const nf_len = r.rem();
    const nf = r.strn(nf_len, STR_CAP);
    try r.require();
    try b.puts("{\"type\":\"ROTATE_EVENT\",\"timestamp\":");
    try b.uint(h.timestamp);
    try b.puts(",\"position\":");
    try b.uint(position);
    try b.puts(",\"next_file\":");
    try b.jsonStr(nf);
    try b.putc('}');
}

fn parseUnknown(h: EventHeader, b: *Serializer) !void {
    try b.puts("{\"type\":\"UNKNOWN\",\"timestamp\":");
    try b.uint(h.timestamp);
    try b.puts(",\"type_id\":");
    try b.uint(h.event_type);
    try b.puts(",\"event_size\":");
    try b.uint(h.event_size);
    try b.putc('}');
}

/// Dispatch a single verified event body to its named handler.
fn dispatchEvent(h: EventHeader, body: []const u8, reg: *Registry,
                 b: *Serializer) !void {
    var r = ByteReader{ .data = body };
    switch (h.event_type) {
        EV_FORMAT_DESC => try parseFde(&r, h, b),
        EV_GTID => try parseGtid(&r, h, b),
        EV_QUERY => try parseQuery(&r, h, b),
        EV_ROWS_QUERY => try parseRowsQuery(&r, h, b),
        EV_TABLE_MAP => try parseTableMap(&r, h, reg, b),
        EV_WRITE_ROWS_V2, EV_UPDATE_ROWS_V2, EV_DELETE_ROWS_V2 =>
            try parseRowsV2(&r, h, reg, b),
        EV_XID => try parseXid(&r, h, b),
        EV_ROTATE => try parseRotate(&r, h, b),
        else => try parseUnknown(h, b), // UNKNOWN -> stable skip
    }
}

// ==================================================================
// [7] Public API: whole-buffer parser.
// ==================================================================
pub fn parseBuffer(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len < MAGIC_SIZE) return error.Invalid;
    for (MAGIC, 0..) |m, i| if (data[i] != m) return error.Invalid;

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    var reg = Registry{};
    var pos: usize = MAGIC_SIZE;
    while (pos < data.len) {
        if (data.len - pos < HEADER_SIZE) return error.Truncated;
        const h = try parseHeader(data[pos .. pos + HEADER_SIZE]);
        const es: usize = h.event_size;
        if (es < HEADER_SIZE + CRC_SIZE or es > MAX_EVENT_SIZE or es > data.len - pos)
            return error.Truncated;
        const full = data[pos .. pos + es];
        // Every event in the controlled subset carries CRC32 (FDE declares
        // checksum_alg=1), so it is verified unconditionally here.
        const stored = try peekLe(full, es - CRC_SIZE, CRC_SIZE);
        const calc: u32 = crc32(full[0 .. es - CRC_SIZE]);
        if (stored != @as(u64, calc)) return error.Checksum;

        const body = full[HEADER_SIZE .. es - CRC_SIZE];
        var b = Serializer.init(allocator, LINE_CAP);
        defer b.deinit();
        try dispatchEvent(h, body, &reg, &b);
        try w.writeAll(try b.finish());
        try w.writeByte('\n');
        pos += es;
    }
    return out.toOwnedSlice();
}

// ==================================================================
// Unit tests (mirror c/tests/test_parser.c).
// ==================================================================
fn putLe(p: []u8, off: usize, v: u64, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        p[off + i] = @truncate(v >> @as(u6, @intCast(8 * i)));
    }
}

fn buildEvent(allocator: std.mem.Allocator, event_type: u8,
              crc_override: ?u32, body: []const u8) ![]u8 {
    const es = HEADER_SIZE + body.len + CRC_SIZE;
    var buf = try allocator.alloc(u8, MAGIC_SIZE + es);
    @memcpy(buf[0..MAGIC_SIZE], MAGIC[0..]);
    putLe(buf, 4, 1, 4);
    buf[8] = event_type;
    putLe(buf, 9, 1, 4);
    putLe(buf, 13, es, 4);
    putLe(buf, 17, es + MAGIC_SIZE, 4);
    putLe(buf, 21, 0, 2);
    @memcpy(buf[23 .. 23 + body.len], body);
    const c = crc_override orelse crc32(buf[4 .. 4 + HEADER_SIZE + body.len]);
    putLe(buf, buf.len - 4, c, 4);
    return buf;
}

test "crc32 vector" {
    try std.testing.expectEqual(@as(u32, 0xCBF4_3926), crc32("123456789"));
}

test "parse header" {
    var h: [19]u8 = [_]u8{0} ** 19;
    putLe(&h, 0, 1700000000, 4);
    h[4] = 15;
    putLe(&h, 5, 1, 4);
    putLe(&h, 9, 119, 4);
    putLe(&h, 13, 123, 4);
    putLe(&h, 17, 0, 2);
    const out = try parseHeader(&h);
    try std.testing.expectEqual(@as(u32, 1700000000), out.timestamp);
    try std.testing.expectEqual(@as(u8, 15), out.event_type);
    try std.testing.expectEqual(@as(u32, 1), out.server_id);
    try std.testing.expectEqual(@as(u32, 119), out.event_size);
    try std.testing.expectEqual(@as(u32, 123), out.next_position);
    try std.testing.expectEqual(@as(u16, 0), out.flags);
}

test "truncated and empty header" {
    try std.testing.expectError(error.Truncated, parseHeader(&[_]u8{0} ** 10));
    try std.testing.expectError(error.Truncated, parseHeader(&[_]u8{}));
}

test "bad magic and empty buffer" {
    try std.testing.expectError(error.Invalid, parseBuffer(std.testing.allocator, &[_]u8{ 0, 0, 0, 0 }));
    try std.testing.expectError(error.Invalid, parseBuffer(std.testing.allocator, &[_]u8{}));
}

test "valid unknown event" {
    const ev = try buildEvent(std.testing.allocator, 99, null, &[_]u8{ 1, 2, 3 });
    defer std.testing.allocator.free(ev);
    const out = try parseBuffer(std.testing.allocator, ev);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        "{\"type\":\"UNKNOWN\",\"timestamp\":1,\"type_id\":99,\"event_size\":26}\n",
        out,
    );
}

test "crc mismatch" {
    const ev = try buildEvent(std.testing.allocator, 99, 0, &[_]u8{});
    defer std.testing.allocator.free(ev);
    try std.testing.expectError(error.Checksum, parseBuffer(std.testing.allocator, ev));
}

test "trailing partial header" {
    const ev = try buildEvent(std.testing.allocator, 99, null, &[_]u8{});
    defer std.testing.allocator.free(ev);
    var raw = try std.testing.allocator.alloc(u8, ev.len + 3);
    defer std.testing.allocator.free(raw);
    @memcpy(raw[0..ev.len], ev);
    raw[ev.len] = 1;
    raw[ev.len + 1] = 2;
    raw[ev.len + 2] = 3;
    try std.testing.expectError(error.Truncated, parseBuffer(std.testing.allocator, raw));
}

test "event size too small and oversized" {
    {
        const ev = try buildEvent(std.testing.allocator, 99, null, &[_]u8{});
        defer std.testing.allocator.free(ev);
        putLe(ev, 4 + 9, 10, 4);
        putLe(ev, ev.len - 4, crc32(ev[4 .. ev.len - 4]), 4);
        try std.testing.expectError(error.Truncated, parseBuffer(std.testing.allocator, ev));
    }
    {
        const ev = try buildEvent(std.testing.allocator, 99, null, &[_]u8{});
        defer std.testing.allocator.free(ev);
        putLe(ev, 4 + 9, 0xFFFF_FFFF, 4);
        putLe(ev, ev.len - 4, crc32(ev[4 .. ev.len - 4]), 4);
        try std.testing.expectError(error.Truncated, parseBuffer(std.testing.allocator, ev));
    }
}

// End-to-end golden verification for Zig is performed by the CI step
// `diff -u fixtures/expected.jsonl out.jsonl` (same as C / C++ / asm).
// Zig 0.13 forbids @embedFile outside the module package root, so the
// fixture is not embedded here.
