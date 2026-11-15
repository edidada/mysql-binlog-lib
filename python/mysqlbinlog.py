"""Phase 1 offline MySQL binlog parser (Python, standard library only).

Layered structure (mirrors ``c/src/mysqlbinlog.c``):

  [1] ByteReader     bounds-checked little-endian primitives
  [2] CRC-32         IEEE / zlib checksum
  [3] Serializer     canonical JSONL builder (fixed key order, no spaces)
  [4] SchemaRegistry table_id -> TableSchema
  [5] RowDecoder     decode RowsEventV2 rows using a registered schema
  [6] EventParser    frame/verify/dispatch events -> one JSONL line each
  [7] Public API     parse_header / crc32 / parse_buffer

The public API and the canonical JSONL are a cross-language contract shared by
the other nine implementations and fixtures/expected.jsonl. Do not change
either without a cross-language update. Every language writes its own
[3] Serializer by hand (no json.dumps) so key order, spacing and escaping stay
byte-identical.
"""

# ==================================================================
# [0] Protocol constants (docs/design.md sections 2-3).
# ==================================================================
MAGIC = b"\xfe\x62\x69\x6e"
HEADER_SIZE = 19
CRC_SIZE = 4
MAGIC_SIZE = 4

MAX_COLS = 64
MAX_TABLES = 64
MAX_EVENT_SIZE = 256 * 1024 * 1024   # defence against corrupt event sizes
LINE_CAP = 16384                     # max single JSONL line
STR_CAP = 2048                       # max query / next_file string
VALUE_CAP = 512                      # max VARCHAR value
NAME_CAP = 128                       # max db / table name

TYPE_LONG = 3
TYPE_LONGLONG = 8
TYPE_VARCHAR = 15

EV_QUERY = 2
EV_ROTATE = 4
EV_FORMAT_DESC = 15
EV_XID = 16
EV_TABLE_MAP = 19
EV_ROWS_QUERY = 29
EV_WRITE_ROWS_V2 = 30
EV_UPDATE_ROWS_V2 = 31
EV_DELETE_ROWS_V2 = 32
EV_GTID = 33


class ParseError(Exception):
    """Parse failure carrying one of the shared status codes."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


def _signed(v, bits):
    """Interpret an unsigned little-endian read as a two's-complement int."""
    v &= (1 << bits) - 1
    if v >= (1 << (bits - 1)):
        v -= 1 << bits
    return v


# ==================================================================
# [1] ByteReader: every read is bounds-checked; ``error`` latches.
# ==================================================================
class ByteReader:
    def __init__(self, data):
        self.data = data
        self.len = len(data)
        self.pos = 0
        self.error = False

    def rem(self):
        return self.len - self.pos if self.pos <= self.len else 0

    def can(self, n):
        """Overflow-safe ``pos + n <= len`` test."""
        return (not self.error) and n >= 0 and n <= self.len and self.pos <= self.len - n

    def _fail(self, code="truncated"):
        self.error = True
        raise ParseError(code)

    def le(self, n):
        if n > 8 or not self.can(n):
            self._fail()
        v = 0
        for i in range(n):
            v |= self.data[self.pos + i] << (8 * i)
        self.pos += n
        return v

    def raw(self, n):
        if not self.can(n):
            self._fail()
        b = self.data[self.pos:self.pos + n]
        self.pos += n
        return b

    def strn(self, n, cap=STR_CAP):
        """Read exactly n bytes as a bounded NUL-terminated string.

        The reader always advances by n (alignment is preserved) even if the
        string is truncated to fit cap, matching c/src/mysqlbinlog.c rd_strn.
        """
        if cap == 0:
            return ""
        if not self.can(n):
            self._fail()
        m = min(n, cap - 1)
        s = bytes(self.data[self.pos:self.pos + m]).decode("utf-8", "replace")
        self.pos += n
        return s

    def skip(self, n):
        if not self.can(n):
            self._fail()
        self.pos += n

    def lenenc(self):
        """MySQL length-encoded integer; 0xFB/0xFF are not valid lengths."""
        b = self.le(1)
        if b < 0xFB:
            return b
        if b == 0xFC:
            return self.le(2)
        if b == 0xFD:
            return self.le(3)
        if b == 0xFE:
            return self.le(8)
        # 0xFB (NULL) and 0xFF (reserved) cannot be used as a length.
        self._fail("unsupported")


# ==================================================================
# [2] CRC-32 (IEEE 802.3 / zlib). Vector: crc32(b"123456789") == 0xCBF43926.
# ==================================================================
def crc32(data):
    c = 0xFFFFFFFF
    for b in data:
        c ^= b
        for _ in range(8):
            mask = 0xEDB88320 if (c & 1) else 0
            c = (c >> 1) ^ mask
    return c ^ 0xFFFFFFFF


def _peek_le32(p):
    return int.from_bytes(p[:4], "little")


# ==================================================================
# [3] Serializer: bounded canonical JSONL builder.
# ==================================================================
class Serializer:
    """Fixed key order, no spaces, minimal escaping, bounded output."""

    def __init__(self, cap=LINE_CAP):
        self.cap = cap
        self.length = 0
        self.overflow = False
        self._parts = []

    def _append(self, s):
        if self.overflow:
            return
        if self.length + len(s) > self.cap:
            self.overflow = True
            return
        self._parts.append(s)
        self.length += len(s)

    def putc(self, c):
        self._append(c)

    def puts(self, s):
        self._append(s)

    def uint(self, v):
        self._append(str(v))

    def json_str(self, s):
        """Minimal JSON escaping: quotes, backslash, control characters."""
        self.putc('"')
        for ch in s:
            o = ord(ch)
            if ch == '"':
                self.puts('\\"')
            elif ch == "\\":
                self.puts("\\\\")
            elif ch == "\n":
                self.puts("\\n")
            elif ch == "\r":
                self.puts("\\r")
            elif ch == "\t":
                self.puts("\\t")
            elif o < 0x20:
                self.puts("\\u%04x" % o)
            else:
                self.putc(ch)
        self.putc('"')

    def line(self):
        return "".join(self._parts)


# ==================================================================
# [4] SchemaRegistry: table_id -> TableSchema, per-file lifetime.
# ==================================================================
class TableSchema:
    __slots__ = ("db", "table", "column_types", "varchar_len_bytes",
                 "nullable_count")

    def __init__(self, db, table, column_types, varchar_len_bytes,
                 nullable_count):
        self.db = db
        self.table = table
        self.column_types = column_types
        self.varchar_len_bytes = varchar_len_bytes
        self.nullable_count = nullable_count


class SchemaRegistry:
    def __init__(self):
        self.entries = {}

    def put(self, table_id, schema):
        """Replace an existing entry, or add one while under the cap."""
        if table_id in self.entries or len(self.entries) < MAX_TABLES:
            self.entries[table_id] = schema

    def get(self, table_id):
        return self.entries.get(table_id)


# ==================================================================
# [5] RowDecoder: decode a row sequence against a TableSchema.
# ==================================================================
def decode_value(r, s, col, is_null, b):
    """Decode one column value and append it to the JSON builder."""
    if is_null:
        b.puts("null")
        return

    ct = s.column_types[col]
    if ct == TYPE_LONGLONG:
        b.uint(_signed(r.le(8), 64))
    elif ct == TYPE_LONG:
        b.uint(_signed(r.le(4), 32))
    elif ct == TYPE_VARCHAR:
        lb = s.varchar_len_bytes[col]
        if lb not in (1, 2):
            raise ParseError("unsupported")
        slen = r.le(lb)
        if slen > VALUE_CAP - 1:
            raise ParseError("unsupported")
        b.json_str(r.strn(slen, VALUE_CAP))
    else:
        raise ParseError("unsupported")


def decode_rows(r, s, present_bitmap, b):
    """Emit the ``,"rows":[...]}`` tail of a RowsEventV2 record."""
    nb_size = (s.nullable_count + 7) // 8
    if nb_size > 8:
        raise ParseError("unsupported")

    b.puts(',"rows":[')
    rowno = 0
    while r.rem() > 0:
        null_bitmap = r.le(nb_size)
        if rowno:
            b.putc(',')
        b.putc('[')
        first = True
        for i in range(len(s.column_types)):
            if not (present_bitmap & (1 << i)):
                continue
            if not first:
                b.putc(',')
            first = False
            decode_value(r, s, i, (null_bitmap & (1 << i)) != 0, b)
        b.putc(']')
        rowno += 1
    b.puts(']}')


# ==================================================================
# [6] EventParser: header, framing, per-event dispatch.
# ==================================================================
def parse_header(data):
    if data is None or len(data) < HEADER_SIZE:
        raise ParseError("truncated")
    r = ByteReader(data)
    h = {
        "timestamp": r.le(4),
        "event_type": r.le(1),
        "server_id": r.le(4),
        "event_size": r.le(4),
        "next_position": r.le(4),
        "flags": r.le(2),
    }
    if r.error:
        raise ParseError("truncated")
    return h


def _rows_name(t):
    if t == EV_WRITE_ROWS_V2:
        return "WRITE_ROWS_EVENT_V2"
    if t == EV_UPDATE_ROWS_V2:
        return "UPDATE_ROWS_EVENT_V2"
    if t == EV_DELETE_ROWS_V2:
        return "DELETE_ROWS_EVENT_V2"
    return "ROWS_EVENT_V2"


def parse_fde(r, h, b):
    if r.rem() < 2 + 50 + 1:
        raise ParseError("truncated")
    bv = r.le(2)
    version_raw = r.raw(50)
    sv = version_raw.split(b"\x00", 1)[0].decode("utf-8", "replace")
    alg = r.data[r.len - 1]

    b.puts('{"type":"FORMAT_DESCRIPTION_EVENT","timestamp":')
    b.uint(h["timestamp"])
    b.puts(',"binlog_version":')
    b.uint(bv)
    b.puts(',"server_version":')
    b.json_str(sv)
    b.puts(',"checksum_alg":')
    b.uint(alg)
    b.putc('}')


def parse_gtid(r, h, b):
    r.le(1)                      # flags
    sid = r.raw(16)
    gno = r.le(8)

    b.puts('{"type":"GTID_LOG_EVENT","timestamp":')
    b.uint(h["timestamp"])
    b.puts(',"gno":')
    b.uint(gno)
    b.puts(',"sid":')
    b.json_str(sid.hex())
    b.putc('}')


def parse_query(r, h, b):
    r.le(4)                      # thread_id
    r.le(4)                      # exec_time
    dbl = r.le(1)
    r.le(2)                      # error_code
    svl = r.le(2)
    r.skip(svl)                  # status_vars
    db = r.strn(dbl, NAME_CAP)
    r.le(1)                      # trailing NUL after db
    query = r.strn(r.rem(), STR_CAP)

    b.puts('{"type":"QUERY_EVENT","timestamp":')
    b.uint(h["timestamp"])
    b.puts(',"db":')
    b.json_str(db)
    b.puts(',"query":')
    b.json_str(query)
    b.putc('}')


def parse_rowsquery(r, h, b):
    ln = r.lenenc()
    q = r.strn(ln, STR_CAP)
    b.puts('{"type":"ROWS_QUERY_LOG_EVENT","timestamp":')
    b.uint(h["timestamp"])
    b.puts(',"query":')
    b.json_str(q)
    b.putc('}')


def parse_table_map(r, h, reg, b):
    tid = r.le(6)
    r.le(2)                      # flags
    dbl = r.le(1)
    db = r.strn(dbl, NAME_CAP)
    r.le(1)                      # NUL
    tbl = r.le(1)
    table = r.strn(tbl, NAME_CAP)
    r.le(1)                      # NUL
    cc = r.lenenc()
    if cc == 0 or cc > MAX_COLS:
        raise ParseError("unsupported")
    types = [r.le(1) for _ in range(cc)]

    md_len = r.lenenc()
    md_start = r.pos
    if md_len > r.len or md_start > r.len - md_len:
        raise ParseError("truncated")

    vlen = [0] * cc
    for i, ct in enumerate(types):
        if ct == TYPE_VARCHAR:
            if r.pos + 2 > md_start + md_len:
                raise ParseError("truncated")
            maxlen = r.le(2)
            vlen[i] = 2 if maxlen > 255 else 1
    r.pos = md_start + md_len    # skip any extra metadata

    nb = (cc + 7) // 8
    if nb > 8:
        raise ParseError("unsupported")
    null_bitmap = r.le(nb)
    nullable = sum(1 for i in range(cc) if null_bitmap & (1 << i))

    reg.put(tid, TableSchema(db, table, types, vlen, nullable))

    b.puts('{"type":"TABLE_MAP_EVENT","timestamp":')
    b.uint(h["timestamp"])
    b.puts(',"table_id":')
    b.uint(tid)
    b.puts(',"db":')
    b.json_str(db)
    b.puts(',"table":')
    b.json_str(table)
    b.puts(',"column_count":')
    b.uint(cc)
    b.puts(',"column_types":[')
    for i, ct in enumerate(types):
        if i:
            b.putc(',')
        b.uint(ct)
    b.puts(']}')


def parse_rows_v2(r, h, reg, b):
    tid = r.le(6)
    r.le(2)                      # flags
    extra_len = r.le(2)          # includes its own 2 bytes
    if extra_len < 2:
        raise ParseError("unsupported")
    r.skip(extra_len - 2)
    cc = r.lenenc()
    if cc == 0 or cc > MAX_COLS:
        raise ParseError("unsupported")
    bm_size = (cc + 7) // 8
    if bm_size > 8:
        raise ParseError("unsupported")
    present = r.le(bm_size)
    if h["event_type"] == EV_UPDATE_ROWS_V2:
        r.le(bm_size)            # before/after bitmap (equal in this subset)

    s = reg.get(tid)
    if s is None:
        raise ParseError("no_schema")

    b.puts('{"type":"')
    b.puts(_rows_name(h["event_type"]))
    b.puts('","timestamp":')
    b.uint(h["timestamp"])
    b.puts(',"table_id":')
    b.uint(tid)
    b.puts(',"db":')
    b.json_str(s.db)
    b.puts(',"table":')
    b.json_str(s.table)
    decode_rows(r, s, present, b)


def parse_xid(r, h, b):
    xid = r.le(8)
    b.puts('{"type":"XID_EVENT","timestamp":')
    b.uint(h["timestamp"])
    b.puts(',"xid":')
    b.uint(xid)
    b.putc('}')


def parse_rotate(r, h, b):
    position = r.le(8)
    next_file = r.strn(r.rem(), STR_CAP)
    b.puts('{"type":"ROTATE_EVENT","timestamp":')
    b.uint(h["timestamp"])
    b.puts(',"position":')
    b.uint(position)
    b.puts(',"next_file":')
    b.json_str(next_file)
    b.putc('}')


def parse_unknown(h, es, b):
    b.puts('{"type":"UNKNOWN","timestamp":')
    b.uint(h["timestamp"])
    b.puts(',"type_id":')
    b.uint(h["event_type"])
    b.puts(',"event_size":')
    b.uint(es)
    b.putc('}')


def dispatch_event(h, body, reg, b):
    """Dispatch a single verified event body to its handler."""
    r = ByteReader(body)
    t = h["event_type"]

    if t == EV_FORMAT_DESC:
        return parse_fde(r, h, b)
    if t == EV_GTID:
        return parse_gtid(r, h, b)
    if t == EV_QUERY:
        return parse_query(r, h, b)
    if t == EV_ROWS_QUERY:
        return parse_rowsquery(r, h, b)
    if t == EV_TABLE_MAP:
        return parse_table_map(r, h, reg, b)
    if t in (EV_WRITE_ROWS_V2, EV_UPDATE_ROWS_V2, EV_DELETE_ROWS_V2):
        return parse_rows_v2(r, h, reg, b)
    if t == EV_XID:
        return parse_xid(r, h, b)
    if t == EV_ROTATE:
        return parse_rotate(r, h, b)
    # UNKNOWN -> safe skip, stable one-line record.
    return parse_unknown(h, h["event_size"], b)


# ==================================================================
# [7] Public API: whole-buffer parser.
# ==================================================================
def parse_buffer(data):
    """Parse a whole binlog buffer; return canonical JSONL (trailing newline)."""
    if data is None or len(data) < MAGIC_SIZE:
        raise ParseError("invalid")
    if bytes(data[:MAGIC_SIZE]) != MAGIC:
        raise ParseError("invalid")

    reg = SchemaRegistry()
    lines = []
    pos = MAGIC_SIZE

    while pos < len(data):
        if len(data) - pos < HEADER_SIZE:
            raise ParseError("truncated")
        h = parse_header(data[pos:pos + HEADER_SIZE])

        es = h["event_size"]
        if (es < HEADER_SIZE + CRC_SIZE or es > MAX_EVENT_SIZE
                or es > len(data) - pos):
            raise ParseError("truncated")

        full = data[pos:pos + es]
        # Every event in the controlled subset carries CRC32 (FDE declares
        # checksum_alg=1), so it is verified unconditionally here.
        stored = _peek_le32(bytes(full[es - CRC_SIZE:es]))
        calc = crc32(bytes(full[:es - CRC_SIZE]))
        if stored != calc:
            raise ParseError("checksum")

        body = full[HEADER_SIZE:es - CRC_SIZE]
        b = Serializer()
        dispatch_event(h, body, reg, b)
        if b.overflow:
            raise ParseError("invalid")
        lines.append(b.line())
        pos += es

    return "".join(line + "\n" for line in lines)
