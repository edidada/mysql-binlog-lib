#!/usr/bin/env python3
"""Deterministic MySQL binlog fixture generator + golden JSONL oracle.

This script is the SINGLE SOURCE OF TRUTH for the cross-language golden test.
It builds a small, well-defined subset of the MySQL Version-4 binlog format and
writes two files:

  fixtures/demo.bin        raw binlog bytes (magic + events, CRC32 per event)
  fixtures/expected.jsonl  canonical JSONL that every language CLI MUST emit
                           when parsing demo.bin with `--format jsonl`

The four language implementations (c/, cpp/, rust/, go/) do NOT import this
script; they independently decode demo.bin and must reproduce expected.jsonl
byte-for-byte. It is regenerated inside GitHub Actions and checked with
`git diff --exit-code` so the committed fixtures can never drift.

Controlled subset (documented in docs/design.md):
  * file magic FE 62 69 6E ("\xfebin")
  * 19-byte little-endian event header
  * every event framed as: header(19) + body + CRC32(4), where the CRC32
    (standard zlib/IEEE, stored little-endian u32) covers header+body
  * FORMAT_DESCRIPTION_EVENT declares checksum_alg = 1 (CRC32)
  * ROW format, binlog_row_image = FULL, no encryption/compression
  * one table: financial_db.transactions(id LONGLONG, user_id LONG, note VARCHAR)

Run:  python3 fixtures/gen_fixture.py
"""
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
BIN_PATH = os.path.join(HERE, "demo.bin")
GOLDEN_PATH = os.path.join(HERE, "expected.jsonl")

MAGIC = b"\xfe\x62\x69\x6e"
SERVER_ID = 1
TABLE_ID = 108
DB = "financial_db"
TABLE = "transactions"
COLUMN_TYPES = [8, 3, 15]  # LONGLONG, LONG, VARCHAR
VARCHAR_MAXLEN = 64
BASE_TS = 1700000000


# ---- little-endian primitives -------------------------------------------------
def le_u16(n):
    return struct.pack("<H", n)


def le_u32(n):
    return struct.pack("<I", n)


def le_u64(n):
    return struct.pack("<Q", n)


def le_i32(n):
    return struct.pack("<i", n)


def le_i64(n):
    return struct.pack("<q", n)


def u48(n):
    return n.to_bytes(6, "little")


# ---- canonical JSON (no spaces, fixed key order, shared by all languages) ----
def q(s):
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif o < 0x20:
            out.append("\\u%04x" % o)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def jval(v):
    if v is None:
        return "null"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        return q(v)
    raise TypeError("unsupported value: %r" % (v,))


def jarr(vals):
    return "[" + ",".join(jval(v) for v in vals) + "]"


def jrows(rows):
    return "[" + ",".join(jarr(r) for r in rows) + "]"


# ---- event assembly -----------------------------------------------------------
blob = [MAGIC]
lines = []
pos = len(MAGIC)
idx = 0


def add(type_id, body, make_line):
    """Append one event; make_line(ts, event_size) -> canonical JSONL line."""
    global pos, idx
    ts = BASE_TS + idx
    idx += 1
    event_size = 19 + len(body) + 4
    next_pos = pos + event_size
    header = struct.pack(
        "<IBIIIH", ts, type_id, SERVER_ID, event_size, next_pos, 0
    )
    frame = header + body
    crc = zlib.crc32(frame) & 0xFFFFFFFF
    blob.append(frame + struct.pack("<I", crc))
    pos = next_pos
    lines.append(make_line(ts, event_size))


def rows_body(type_id, rows):
    """Rows v2 body: table_id + flags + extra_data_len(2) + col_count +
    columns_present bitmap(s) + rows."""
    b = u48(TABLE_ID) + le_u16(0) + le_u16(2) + bytes([3]) + bytes([0x07])
    if type_id == 31:  # UPDATE_ROWS_EVENT_V2 has before + after bitmaps
        b += bytes([0x07])
    for r in rows:
        b += enc_row(r)
    return b


def enc_row(values):
    """One row: null_bitmap(1 byte, 3 nullable cols) + present column values."""
    bm = 0
    for i, v in enumerate(values):
        if v is None:
            bm |= 1 << i
    out = bytes([bm])
    for i, v in enumerate(values):
        if v is None:
            continue
        if i == 0:
            out += le_i64(v)  # LONGLONG
        elif i == 1:
            out += le_i32(v)  # LONG
        elif i == 2:
            out += bytes([len(v)]) + v.encode()  # VARCHAR, 1-byte length
    return out


# 1. FORMAT_DESCRIPTION_EVENT (15)
# body = binlog_version(2) + server_version(50) + create_ts(4) +
#        common_header_len(1) + post_header_len(38, ignored) + checksum_alg(1)
fde_body = (
    le_u16(4)
    + b"8.0.36".ljust(50, b"\x00")
    + le_u32(0)
    + bytes([19])
    + bytes(38)
    + bytes([1])
)
add(
    15,
    fde_body,
    lambda t, s: (
        '{"type":"FORMAT_DESCRIPTION_EVENT","timestamp":%d,'
        '"binlog_version":4,"server_version":%s,"checksum_alg":1}' % (t, q("8.0.36"))
    ),
)

# 2. UNKNOWN event (99) -> exercises safe skip of unhandled types
add(
    99,
    bytes([0x01, 0x02, 0x03]),
    lambda t, s: (
        '{"type":"UNKNOWN","timestamp":%d,"type_id":99,"event_size":%d}' % (t, s)
    ),
)

# 3. GTID_LOG_EVENT (33): flags(1) + sid(16) + gno(8)
sid = bytes(range(16))
add(
    33,
    bytes([0]) + sid + le_u64(42),
    lambda t, s: (
        '{"type":"GTID_LOG_EVENT","timestamp":%d,"gno":42,"sid":%s}'
        % (t, q(sid.hex()))
    ),
)

# 4. QUERY_EVENT (2): BEGIN
query_begin = b"BEGIN"
query_body = (
    le_u32(1)                      # thread_id
    + le_u32(0)                    # exec_time
    + bytes([len(DB)])             # db_len
    + le_u16(0)                    # error_code
    + le_u16(0)                    # status_vars_len
    + b""                          # status_vars
    + DB.encode()
    + b"\x00"
    + query_begin
)
add(
    2,
    query_body,
    lambda t, s: (
        '{"type":"QUERY_EVENT","timestamp":%d,"db":%s,"query":%s}'
        % (t, q(DB), q("BEGIN"))
    ),
)

# 5. ROWS_QUERY_LOG_EVENT (29): length-prefixed string
rquery = "INSERT INTO transactions"
add(
    29,
    bytes([len(rquery)]) + rquery.encode(),
    lambda t, s: (
        '{"type":"ROWS_QUERY_LOG_EVENT","timestamp":%d,"query":%s}'
        % (t, q(rquery))
    ),
)

# 6. TABLE_MAP_EVENT (19): table_id(6) + flags(2) + db + NUL + table + NUL +
#    column_count(lenenc) + column_types + metadata_len(lenenc) + metadata +
#    null_bitmap
table_map_body = (
    u48(TABLE_ID)
    + le_u16(0)
    + bytes([len(DB)]) + DB.encode() + b"\x00"
    + bytes([len(TABLE)]) + TABLE.encode() + b"\x00"
    + bytes([3])
    + bytes(COLUMN_TYPES)
    + bytes([2])
    + le_u16(VARCHAR_MAXLEN)
    + bytes([0x07])  # 3 nullable columns
)
add(
    19,
    table_map_body,
    lambda t, s: (
        '{"type":"TABLE_MAP_EVENT","timestamp":%d,"table_id":%d,"db":%s,'
        '"table":%s,"column_count":3,"column_types":%s}'
        % (t, TABLE_ID, q(DB), q(TABLE), jarr(COLUMN_TYPES))
    ),
)

# 7. WRITE_ROWS_EVENT_V2 (30): one row
write_rows = [[1001, 7, "insert"]]
add(
    30,
    rows_body(30, write_rows),
    lambda t, s: (
        '{"type":"WRITE_ROWS_EVENT_V2","timestamp":%d,"table_id":%d,"db":%s,'
        '"table":%s,"rows":%s}'
        % (t, TABLE_ID, q(DB), q(TABLE), jrows(write_rows))
    ),
)

# 8. UPDATE_ROWS_EVENT_V2 (31): before + after (after.note is NULL)
update_rows = [[1002, 8, "before"], [1002, 8, None]]
add(
    31,
    rows_body(31, update_rows),
    lambda t, s: (
        '{"type":"UPDATE_ROWS_EVENT_V2","timestamp":%d,"table_id":%d,"db":%s,'
        '"table":%s,"rows":%s}'
        % (t, TABLE_ID, q(DB), q(TABLE), jrows(update_rows))
    ),
)

# 9. DELETE_ROWS_EVENT_V2 (32): one row
delete_rows = [[1003, 9, "delete"]]
add(
    32,
    rows_body(32, delete_rows),
    lambda t, s: (
        '{"type":"DELETE_ROWS_EVENT_V2","timestamp":%d,"table_id":%d,"db":%s,'
        '"table":%s,"rows":%s}'
        % (t, TABLE_ID, q(DB), q(TABLE), jrows(delete_rows))
    ),
)

# 10. XID_EVENT (16): xid(8)
add(
    16,
    le_u64(12345),
    lambda t, s: '{"type":"XID_EVENT","timestamp":%d,"xid":12345}' % t,
)

# 11. ROTATE_EVENT (4): position(8) + next_file
add(
    4,
    le_u64(4) + b"mysql-bin.000002",
    lambda t, s: (
        '{"type":"ROTATE_EVENT","timestamp":%d,"position":4,"next_file":%s}'
        % (t, q("mysql-bin.000002"))
    ),
)

with open(BIN_PATH, "wb") as f:
    f.write(b"".join(blob))
with open(GOLDEN_PATH, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(lines) + "\n")

print("wrote %s (%d bytes, %d events)" % (BIN_PATH, pos, idx))
print("wrote %s (%d lines)" % (GOLDEN_PATH, len(lines)))
