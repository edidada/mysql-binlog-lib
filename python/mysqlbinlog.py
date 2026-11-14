"""Phase 1 offline MySQL binlog parser (Python, standard library only).

Decodes the controlled subset described in docs/design.md and emits the
canonical JSONL shared by every language implementation.
"""

import json


class ParseError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


class _Reader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def rem(self):
        return len(self.data) - self.pos

    def le(self, n):
        if n < 0 or n > 8 or self.pos + n > len(self.data):
            raise ParseError("truncated")
        v = 0
        for i in range(n):
            v |= self.data[self.pos + i] << (8 * i)
        self.pos += n
        return v

    def raw(self, n):
        if n < 0 or self.pos + n > len(self.data):
            raise ParseError("truncated")
        b = self.data[self.pos:self.pos + n]
        self.pos += n
        return b

    def text(self, n):
        return self.raw(n).decode("utf-8")

    def skip(self, n):
        self.raw(n)

    def lenenc(self):
        b = self.le(1)
        if b < 0xFB:
            return b
        if b == 0xFB:
            return 0
        if b == 0xFC:
            return self.le(2)
        if b == 0xFD:
            return self.le(3)
        if b == 0xFE:
            return self.le(8)
        return 0


def crc32(data):
    """CRC-32 (IEEE / zlib), implemented bitwise so unit tests are meaningful."""
    c = 0xFFFFFFFF
    for b in data:
        c ^= b
        for _ in range(8):
            mask = 0xEDB88320 if (c & 1) else 0
            c = (c >> 1) ^ mask
    return c ^ 0xFFFFFFFF


def _le(data, off, n):
    v = 0
    for i in range(n):
        v |= data[off + i] << (8 * i)
    return v


def parse_header(data):
    if len(data) < 19:
        raise ParseError("truncated")
    r = _Reader(data)
    return {
        "timestamp": r.le(4),
        "event_type": r.le(1),
        "server_id": r.le(4),
        "event_size": r.le(4),
        "next_position": r.le(4),
        "flags": r.le(2),
    }


def _rows_name(t):
    if t == 30:
        return "WRITE_ROWS_EVENT_V2"
    if t == 31:
        return "UPDATE_ROWS_EVENT_V2"
    if t == 32:
        return "DELETE_ROWS_EVENT_V2"
    return "ROWS_EVENT_V2"


def parse_buffer(data):
    """Parse a whole binlog buffer; return canonical JSONL (trailing newline)."""
    if len(data) < 4:
        raise ParseError("invalid")
    if data[:4] != b"\xfe\x62\x69\x6e":
        raise ParseError("invalid")

    registry = {}
    lines = []
    pos = 4  # skip magic
    while pos < len(data):
        if pos + 19 > len(data):
            raise ParseError("truncated")
        h = parse_header(data[pos:pos + 19])
        es = h["event_size"]
        if es < 23 or pos + es > len(data):
            raise ParseError("truncated")
        full = data[pos:pos + es]
        stored = _le(full, es - 4, 4)
        if crc32(full[:es - 4]) != stored:
            raise ParseError("checksum")
        body = full[19:es - 4]
        r = _Reader(body)
        t = h["event_type"]
        ts = h["timestamp"]

        if t == 15:  # FORMAT_DESCRIPTION_EVENT
            bv = r.le(2)
            tmp = r.raw(50)
            sv = tmp.split(b"\x00", 1)[0].decode("utf-8")
            alg = body[-1]
            obj = {
                "type": "FORMAT_DESCRIPTION_EVENT", "timestamp": ts,
                "binlog_version": bv, "server_version": sv, "checksum_alg": alg,
            }
        elif t == 33:  # GTID_LOG_EVENT
            r.le(1)  # flags
            sid = r.raw(16)
            gno = r.le(8)
            obj = {"type": "GTID_LOG_EVENT", "timestamp": ts,
                   "gno": gno, "sid": sid.hex()}
        elif t == 2:  # QUERY_EVENT
            r.le(4)  # thread_id
            r.le(4)  # exec_time
            dbl = r.le(1)
            r.le(2)  # error_code
            svl = r.le(2)
            r.skip(svl)
            db = r.text(dbl)
            r.le(1)  # trailing NUL
            query = r.text(r.rem())
            obj = {"type": "QUERY_EVENT", "timestamp": ts,
                   "db": db, "query": query}
        elif t == 29:  # ROWS_QUERY_LOG_EVENT
            ln = r.lenenc()
            q = r.text(ln)
            obj = {"type": "ROWS_QUERY_LOG_EVENT", "timestamp": ts, "query": q}
        elif t == 19:  # TABLE_MAP_EVENT
            tid = r.le(6)
            r.le(2)  # flags
            dbl = r.le(1)
            db = r.text(dbl)
            r.le(1)  # NUL
            tbl = r.le(1)
            table = r.text(tbl)
            r.le(1)  # NUL
            cc = r.lenenc()
            types = list(r.raw(cc))
            mdlen = r.lenenc()
            mdstart = r.pos
            vlen = [0] * cc
            for i, ct in enumerate(types):
                if ct == 15:
                    mx = r.le(2)
                    vlen[i] = 2 if mx > 255 else 1
            r.pos = mdstart + mdlen
            nb = (cc + 7) // 8
            nullbm = r.le(nb)
            nullable = sum(1 for i in range(cc) if nullbm & (1 << i))
            registry[tid] = {
                "db": db, "table": table, "cc": cc, "types": types,
                "vlen": vlen, "nullable": nullable,
            }
            obj = {
                "type": "TABLE_MAP_EVENT", "timestamp": ts, "table_id": tid,
                "db": db, "table": table, "column_count": cc,
                "column_types": types,
            }
        elif t in (30, 31, 32):  # ROWS_EVENT_V2
            tid = r.le(6)
            r.le(2)  # flags
            el = r.le(2)
            if el >= 2:
                r.skip(el - 2)
            cc = r.lenenc()
            bm = (cc + 7) // 8
            present1 = r.le(bm)
            if t == 31:
                r.le(bm)  # bitmap2, equal
            s = registry.get(tid)
            if s is None:
                raise ParseError("no_schema")
            nbs = (s["nullable"] + 7) // 8
            rows = []
            while r.rem() > 0:
                nullbm = r.le(nbs)
                row = []
                for i in range(s["cc"]):
                    if not (present1 & (1 << i)):
                        continue
                    if nullbm & (1 << i):
                        row.append(None)
                        continue
                    ct = s["types"][i]
                    if ct == 8:
                        row.append(r.le(8))
                    elif ct == 3:
                        row.append(r.le(4))
                    elif ct == 15:
                        lb = s["vlen"][i] or 1
                        slen = r.le(lb)
                        row.append(r.text(slen))
                    else:
                        raise ParseError("unsupported")
                rows.append(row)
            obj = {
                "type": _rows_name(t), "timestamp": ts, "table_id": tid,
                "db": s["db"], "table": s["table"], "rows": rows,
            }
        elif t == 16:  # XID_EVENT
            xid = r.le(8)
            obj = {"type": "XID_EVENT", "timestamp": ts, "xid": xid}
        elif t == 4:  # ROTATE_EVENT
            position = r.le(8)
            nf = r.text(r.rem())
            obj = {"type": "ROTATE_EVENT", "timestamp": ts,
                   "position": position, "next_file": nf}
        else:  # UNKNOWN -> safe skip
            obj = {"type": "UNKNOWN", "timestamp": ts,
                   "type_id": t, "event_size": es}

        lines.append(json.dumps(obj, separators=(",", ":")))
        pos += es
    return "\n".join(lines) + "\n"
