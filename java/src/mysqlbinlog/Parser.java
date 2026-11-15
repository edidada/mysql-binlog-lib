/*
 * CONTRACT (cross-language): the public API in this file (parseBuffer,
 * parseHeader, crc32, Header, BinlogError) and the canonical JSONL emitted by
 * parseBuffer are shared with the other language implementations and with
 * fixtures/expected.jsonl. Do not change either without a cross-language
 * update. Internals are layered, in order, as ByteReader / CRC32 / Serializer /
 * SchemaRegistry / RowDecoder / EventParser (mirrors docs/design.md section 4).
 */
package mysqlbinlog;

import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

/** Offline MySQL binlog parser (Phase 1 controlled subset; JDK only, no deps). */
public final class Parser {

    private Parser() {}

    /* ------------------------------------------------------------------ */
    /* Protocol constants (docs/design.md sections 2 and 3).               */
    /* ------------------------------------------------------------------ */
    static final int HEADER_SIZE = 19;
    static final int CRC_SIZE = 4;
    static final int MAGIC_SIZE = 4;
    static final int MAX_COLS = 64;
    static final int MAX_TABLES = 64;
    static final long MAX_EVENT_SIZE = 256L * 1024 * 1024; /* corrupt-size guard */
    static final int LINE_CAP = 16384;                    /* max single JSONL line */

    /* Column type ids used by the controlled subset. */
    static final int TYPE_LONG = 3;
    static final int TYPE_LONGLONG = 8;
    static final int TYPE_VARCHAR = 15;

    /* Event type ids. */
    static final int EV_QUERY = 2;
    static final int EV_ROTATE = 4;
    static final int EV_FORMAT_DESC = 15;
    static final int EV_XID = 16;
    static final int EV_TABLE_MAP = 19;
    static final int EV_ROWS_QUERY = 29;
    static final int EV_WRITE_ROWS_V2 = 30;
    static final int EV_UPDATE_ROWS_V2 = 31;
    static final int EV_DELETE_ROWS_V2 = 32;
    static final int EV_GTID = 33;

    /* Bounded string caps (defence against corrupt length fields). */
    static final int CAP_DB = 128;
    static final int CAP_TABLE = 128;
    static final int CAP_QUERY = 2048;
    static final int CAP_FILE = 512;
    static final int CAP_VARCHAR = 512;

    static final byte[] MAGIC = { (byte) 0xFE, (byte) 0x62, (byte) 0x69, (byte) 0x6E };
    static final char[] HEX = "0123456789abcdef".toCharArray();

    /* Public API value types (kept for Cli.java and ParserTest.java). */
    public static final class BinlogError extends RuntimeException {
        public final String code;
        BinlogError(String code) {
            super(code);
            this.code = code;
        }
    }

    public static final class Header {
        public long timestamp;
        public int eventType;
        public long serverId;
        public long eventSize;
        public long nextPosition;
        public int flags;
    }

    /* ================================================================== */
    /* [1] ByteReader: every read is bounds-checked; error latches.         */
    /* ================================================================== */
    /* A view [start, start+len) into a backing array. On any violation the
       first error code is latched and reads return safe defaults; requireOk()
       surfaces it as a BinlogError before a line is ever emitted. */
    private static final class ByteReader {
        final byte[] d;
        final int start;
        final int len;
        int pos;
        boolean error;
        String errorCode;

        ByteReader(byte[] d) { this(d, 0, d.length); }

        ByteReader(byte[] d, int start, int len) {
            this.d = d;
            this.start = start;
            this.len = len;
            this.pos = 0;
            this.error = false;
            this.errorCode = null;
            if (start < 0 || len < 0 || start > d.length - len) fail("truncated");
        }

        void fail(String code) {
            if (!error) {           /* first error wins */
                error = true;
                errorCode = code;
            }
        }

        void requireOk() {
            if (error) throw new BinlogError(errorCode);
        }

        int rem() { return error ? 0 : (pos <= len ? len - pos : 0); }

        /* Overflow-safe "pos + n <= len" test; n is a long so huge lenenc
           values cannot wrap around before the comparison. */
        boolean can(long n) {
            return !error && n >= 0 && n <= len && pos <= len - n;
        }

        long le(int n) {
            if (n > 8 || !can(n)) { fail("truncated"); return 0; }
            long v = 0;
            for (int i = 0; i < n; i++) v |= ((long) (d[start + pos + i] & 0xFF)) << (8 * i);
            pos += n;
            return v;
        }

        byte[] raw(int n) {
            if (!can(n)) { fail("truncated"); return new byte[n > 0 ? n : 0]; }
            byte[] out = new byte[n];
            for (int i = 0; i < n; i++) out[i] = d[start + pos + i];
            pos += n;
            return out;
        }

        /* Read exactly n bytes as a string, advancing by n to preserve
           alignment. Output is truncated at the first NUL and bounded to
           cap-1, matching C's rd_strn + sb_json_str behaviour. */
        String strn(long n, int cap) {
            if (cap <= 0) return "";
            if (!can(n)) { fail("truncated"); return ""; }
            int m = (int) Math.min(n, (long) (cap - 1));
            int end = 0;
            while (end < m && d[start + pos + end] != 0) end++;
            String s = new String(d, start + pos, end, StandardCharsets.UTF_8);
            pos += (int) n;
            return s;
        }

        void skip(int n) {
            if (!can(n)) { fail("truncated"); pos = len; return; }
            pos += n;
        }

        /* Peek a single byte at a view-relative index without advancing. */
        int u8At(int index) {
            if (!can(0) || index < 0 || index >= len) { fail("truncated"); return 0; }
            return d[start + index] & 0xFF;
        }

        /* MySQL length-encoded integer. 0xFB (NULL) and 0xFF (reserved) are
           rejected as invalid where a length is required. */
        long lenenc() {
            long b = le(1);
            if (error) return 0;
            if (b < 0xFB) return b;
            if (b == 0xFC) return le(2);
            if (b == 0xFD) return le(3);
            if (b == 0xFE) return le(8);
            fail("invalid");
            return 0;
        }
    }

    /* ================================================================== */
    /* [2] CRC-32 (IEEE 802.3 / zlib), public for unit tests.              */
    /* ================================================================== */
    /** Standard vector: crc32("123456789") == 0xCBF43926. */
    public static long crc32(byte[] data, int off, int len) {
        if (data == null || off < 0 || len < 0 || off > data.length - len)
            throw new BinlogError("truncated");
        int crc = -1;
        for (int i = off; i < off + len; i++) {
            crc ^= (data[i] & 0xFF);
            for (int k = 0; k < 8; k++) {
                int mask = -(crc & 1);
                crc = (crc >>> 1) ^ (0xEDB88320 & mask);
            }
        }
        return (~crc) & 0xFFFFFFFFL;
    }

    /* Little-endian peek over an already CRC-sized region. */
    private static long peekLe32(byte[] d, int off) {
        if (off < 0 || off > d.length - CRC_SIZE) throw new BinlogError("truncated");
        return (d[off] & 0xFFL)
             | ((d[off + 1] & 0xFFL) << 8)
             | ((d[off + 2] & 0xFFL) << 16)
             | ((d[off + 3] & 0xFFL) << 24);
    }

    /* ================================================================== */
    /* [3] Serializer: bounded canonical JSONL builder.                    */
    /* ================================================================== */
    private static final class JsonBuilder {
        private final StringBuilder sb;
        private final int cap;
        private boolean overflow;

        JsonBuilder(int cap) {
            this.sb = new StringBuilder();
            this.cap = cap;
            this.overflow = false;
        }

        private JsonBuilder append(String s) {
            if (overflow) return this;
            if (sb.length() + s.length() >= cap) { overflow = true; return this; }
            sb.append(s);
            return this;
        }

        JsonBuilder putc(char c) { return append(String.valueOf(c)); }
        JsonBuilder putStr(String s) { return append(s); }
        JsonBuilder putLong(long v) { return append(Long.toString(v)); }

        /* Minimal JSON string escaping: quotes, backslash, control chars. */
        JsonBuilder jsonStr(String s) {
            putc('"');
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                switch (c) {
                case '"':  putStr("\\\""); break;
                case '\\': putStr("\\\\"); break;
                case '\n': putStr("\\n");  break;
                case '\r': putStr("\\r");  break;
                case '\t': putStr("\\t");  break;
                default:
                    if (c < 0x20) {
                        putStr("\\u00");
                        putc(HEX[(c >> 4) & 0x0F]);
                        putc(HEX[c & 0x0F]);
                    } else {
                        putc(c);
                    }
                }
            }
            putc('"');
            return this;
        }

        boolean overflow() { return overflow; }
        @Override public String toString() { return sb.toString(); }
    }

    /* ================================================================== */
    /* [4] SchemaRegistry: table_id -> TableSchema, per-file lifetime.      */
    /* ================================================================== */
    private static final class TableSchema {
        long tableId;
        String db = "";
        String table = "";
        int columnCount;
        int[] columnTypes;
        int[] varcharLenBytes;   /* 1 or 2 length-prefix bytes */
        int nullableCount;       /* popcount of the null bitmap */
    }

    private static final class SchemaRegistry {
        private final Map<Long, TableSchema> entries = new HashMap<>();

        /* put replaces an existing key; new keys are dropped once bounded. */
        void put(TableSchema s) {
            if (entries.containsKey(s.tableId)) {
                entries.put(s.tableId, s);
                return;
            }
            if (entries.size() < MAX_TABLES) entries.put(s.tableId, s);
        }

        TableSchema get(long tableId) { return entries.get(tableId); }
    }

    /* ================================================================== */
    /* [5] RowDecoder: decode a row sequence against a TableSchema.        */
    /* ================================================================== */
    private static final class RowDecoder {
        private RowDecoder() {}

        /* Decode one column value and append it to the JSON builder. */
        static void decodeValue(ByteReader r, TableSchema s, int col,
                                boolean isNull, JsonBuilder b) {
            if (isNull) {
                b.putStr("null");
                return;
            }
            switch (s.columnTypes[col]) {
            case TYPE_LONGLONG:
                b.putLong(r.le(8));
                break;
            case TYPE_LONG:
                b.putLong((int) r.le(4));   /* sign-extend like C's int32 */
                break;
            case TYPE_VARCHAR: {
                int lb = s.varcharLenBytes[col];
                if (lb != 1 && lb != 2) throw new BinlogError("unsupported");
                long slen = r.le(lb);
                r.requireOk();
                if (slen > CAP_VARCHAR - 1) throw new BinlogError("unsupported");
                String val = r.strn(slen, CAP_VARCHAR);
                b.jsonStr(val);
                break;
            }
            default:
                throw new BinlogError("unsupported");
            }
            r.requireOk();
        }

        /* Emit the "rows" array (plus the closing object brace). */
        static void decodeRows(ByteReader r, TableSchema s,
                               long presentBitmap, JsonBuilder b) {
            int nbSize = (s.nullableCount + 7) / 8;
            if (nbSize > 8) throw new BinlogError("unsupported");
            b.putStr(",\"rows\":[");
            int rowno = 0;
            while (r.rem() > 0 && !r.error) {
                long nullBitmap = r.le(nbSize);
                if (r.error) break;
                if (rowno > 0) b.putc(',');
                b.putc('[');
                boolean first = true;
                for (int i = 0; i < s.columnCount; i++) {
                    if ((presentBitmap & (1L << i)) == 0) continue;
                    if (!first) b.putc(',');
                    first = false;
                    decodeValue(r, s, i, (nullBitmap & (1L << i)) != 0, b);
                }
                b.putc(']');
                rowno++;
            }
            b.putStr("]}");
            r.requireOk();
        }
    }

    /* ================================================================== */
    /* [6] EventParser: header, per-event handlers, dispatch.              */
    /* ================================================================== */
    private static final class EventParser {
        private final SchemaRegistry registry;

        EventParser(SchemaRegistry registry) { this.registry = registry; }

        static Header readHeader(ByteReader r) {
            Header h = new Header();
            h.timestamp = r.le(4);
            h.eventType = (int) r.le(1);
            h.serverId = r.le(4);
            h.eventSize = r.le(4);
            h.nextPosition = r.le(4);
            h.flags = (int) r.le(2);
            return h;
        }

        private static String rowsName(int t) {
            if (t == EV_WRITE_ROWS_V2) return "WRITE_ROWS_EVENT_V2";
            if (t == EV_UPDATE_ROWS_V2) return "UPDATE_ROWS_EVENT_V2";
            if (t == EV_DELETE_ROWS_V2) return "DELETE_ROWS_EVENT_V2";
            return "ROWS_EVENT_V2";
        }

        /* FORMAT_DESCRIPTION_EVENT (15). */
        private void parseFde(Header h, ByteReader r, JsonBuilder b) {
            int bodyLen = r.len;
            if (bodyLen < 2 + 50 + 1) throw new BinlogError("truncated");
            long binlogVersion = r.le(2);
            byte[] versionRaw = r.raw(50);
            int k = 0;
            while (k < 50 && versionRaw[k] != 0) k++;
            String serverVersion = new String(versionRaw, 0, k, StandardCharsets.UTF_8);
            long checksumAlg = r.u8At(bodyLen - 1);
            r.requireOk();
            b.putStr("{\"type\":\"FORMAT_DESCRIPTION_EVENT\",\"timestamp\":")
             .putLong(h.timestamp)
             .putStr(",\"binlog_version\":").putLong(binlogVersion)
             .putStr(",\"server_version\":").jsonStr(serverVersion)
             .putStr(",\"checksum_alg\":").putLong(checksumAlg)
             .putStr("}");
            r.requireOk();
        }

        /* GTID_LOG_EVENT (33). */
        private void parseGtid(Header h, ByteReader r, JsonBuilder b) {
            r.le(1);                /* flags */
            byte[] sid = r.raw(16);
            long gno = r.le(8);
            r.requireOk();
            StringBuilder sh = new StringBuilder(32);
            for (byte x : sid) {
                sh.append(HEX[(x >> 4) & 0x0F]);
                sh.append(HEX[x & 0x0F]);
            }
            b.putStr("{\"type\":\"GTID_LOG_EVENT\",\"timestamp\":")
             .putLong(h.timestamp)
             .putStr(",\"gno\":").putLong(gno)
             .putStr(",\"sid\":").jsonStr(sh.toString())
             .putStr("}");
        }

        /* QUERY_EVENT (2). */
        private void parseQuery(Header h, ByteReader r, JsonBuilder b) {
            r.le(4);                            /* thread_id */
            r.le(4);                            /* exec_time */
            int dbLen = (int) r.le(1);
            r.le(2);                            /* error_code */
            int svLen = (int) r.le(2);
            r.skip(svLen);                      /* status_vars */
            String db = r.strn(dbLen, CAP_DB);
            r.le(1);                            /* trailing NUL after db */
            String query = r.strn(r.rem(), CAP_QUERY);
            r.requireOk();
            b.putStr("{\"type\":\"QUERY_EVENT\",\"timestamp\":")
             .putLong(h.timestamp)
             .putStr(",\"db\":").jsonStr(db)
             .putStr(",\"query\":").jsonStr(query)
             .putStr("}");
        }

        /* ROWS_QUERY_LOG_EVENT (29). */
        private void parseRowsQuery(Header h, ByteReader r, JsonBuilder b) {
            long len = r.lenenc();
            r.requireOk();
            String q = r.strn(len, CAP_QUERY);
            r.requireOk();
            b.putStr("{\"type\":\"ROWS_QUERY_LOG_EVENT\",\"timestamp\":")
             .putLong(h.timestamp)
             .putStr(",\"query\":").jsonStr(q)
             .putStr("}");
        }

        /* TABLE_MAP_EVENT (19): register the schema and emit its JSON. */
        private void parseTableMap(Header h, ByteReader r, JsonBuilder b) {
            TableSchema s = new TableSchema();
            s.tableId = r.le(6);
            r.le(2);                            /* flags */
            int dbLen = (int) r.le(1);
            s.db = r.strn(dbLen, CAP_DB);
            r.le(1);                            /* NUL */
            int tableLen = (int) r.le(1);
            s.table = r.strn(tableLen, CAP_TABLE);
            r.le(1);                            /* NUL */
            long cc = r.lenenc();
            r.requireOk();
            if (cc == 0 || cc > MAX_COLS) throw new BinlogError("unsupported");
            s.columnCount = (int) cc;
            s.columnTypes = new int[s.columnCount];
            s.varcharLenBytes = new int[s.columnCount];
            for (int i = 0; i < s.columnCount; i++) s.columnTypes[i] = (int) r.le(1);
            long mdLen = r.lenenc();
            r.requireOk();
            int mdStart = r.pos;
            if (mdLen > r.len || mdStart > r.len - mdLen)
                throw new BinlogError("truncated");
            int mdEnd = (int) (mdStart + mdLen);
            for (int i = 0; i < s.columnCount; i++) {
                if (s.columnTypes[i] == TYPE_VARCHAR) {
                    if (r.pos + 2 > mdEnd) throw new BinlogError("truncated");
                    long maxlen = r.le(2);
                    s.varcharLenBytes[i] = (maxlen > 255) ? 2 : 1;
                }
            }
            r.pos = mdEnd;                      /* skip any extra metadata */
            int nb = (s.columnCount + 7) / 8;
            if (nb > 8) throw new BinlogError("unsupported");
            long nullBitmap = r.le(nb);
            r.requireOk();
            int nullable = 0;
            for (int i = 0; i < s.columnCount; i++)
                if ((nullBitmap & (1L << i)) != 0) nullable++;
            s.nullableCount = nullable;
            registry.put(s);

            b.putStr("{\"type\":\"TABLE_MAP_EVENT\",\"timestamp\":")
             .putLong(h.timestamp)
             .putStr(",\"table_id\":").putLong(s.tableId)
             .putStr(",\"db\":").jsonStr(s.db)
             .putStr(",\"table\":").jsonStr(s.table)
             .putStr(",\"column_count\":").putLong(s.columnCount)
             .putStr(",\"column_types\":[");
            for (int i = 0; i < s.columnCount; i++) {
                if (i > 0) b.putc(',');
                b.putLong(s.columnTypes[i]);
            }
            b.putStr("]}");
        }

        /* WRITE/UPDATE/DELETE_ROWS_EVENT_V2 (30/31/32). */
        private void parseRowsV2(Header h, ByteReader r, JsonBuilder b) {
            long tableId = r.le(6);
            r.le(2);                            /* flags */
            long extraLen = r.le(2);            /* includes its own 2 bytes */
            if (extraLen < 2) throw new BinlogError("unsupported");
            r.skip((int) (extraLen - 2));
            long cc = r.lenenc();
            r.requireOk();
            if (cc == 0 || cc > MAX_COLS) throw new BinlogError("unsupported");
            int bmSize = (int) ((cc + 7) / 8);
            if (bmSize > 8) throw new BinlogError("unsupported");
            long presentBitmap = r.le(bmSize);
            if (h.eventType == EV_UPDATE_ROWS_V2) r.le(bmSize); /* 2nd bitmap */
            r.requireOk();
            TableSchema s = registry.get(tableId);
            if (s == null) throw new BinlogError("no_schema");

            b.putStr("{\"type\":\"").putStr(rowsName(h.eventType))
             .putStr("\",\"timestamp\":").putLong(h.timestamp)
             .putStr(",\"table_id\":").putLong(tableId)
             .putStr(",\"db\":").jsonStr(s.db)
             .putStr(",\"table\":").jsonStr(s.table);
            RowDecoder.decodeRows(r, s, presentBitmap, b);
        }

        /* XID_EVENT (16). */
        private void parseXid(Header h, ByteReader r, JsonBuilder b) {
            long xid = r.le(8);
            r.requireOk();
            b.putStr("{\"type\":\"XID_EVENT\",\"timestamp\":")
             .putLong(h.timestamp)
             .putStr(",\"xid\":").putLong(xid)
             .putStr("}");
        }

        /* ROTATE_EVENT (4). */
        private void parseRotate(Header h, ByteReader r, JsonBuilder b) {
            long position = r.le(8);
            String nextFile = r.strn(r.rem(), CAP_FILE);
            r.requireOk();
            b.putStr("{\"type\":\"ROTATE_EVENT\",\"timestamp\":")
             .putLong(h.timestamp)
             .putStr(",\"position\":").putLong(position)
             .putStr(",\"next_file\":").jsonStr(nextFile)
             .putStr("}");
        }

        /* UNKNOWN: safe skip, emit a stable one-line record. */
        private void parseUnknown(Header h, JsonBuilder b) {
            b.putStr("{\"type\":\"UNKNOWN\",\"timestamp\":")
             .putLong(h.timestamp)
             .putStr(",\"type_id\":").putLong(h.eventType)
             .putStr(",\"event_size\":").putLong(h.eventSize)
             .putStr("}");
        }

        /* Dispatch a single verified event body to its handler. */
        void dispatch(Header h, ByteReader r, JsonBuilder b) {
            switch (h.eventType) {
            case EV_FORMAT_DESC:      parseFde(h, r, b); break;
            case EV_GTID:             parseGtid(h, r, b); break;
            case EV_QUERY:            parseQuery(h, r, b); break;
            case EV_ROWS_QUERY:       parseRowsQuery(h, r, b); break;
            case EV_TABLE_MAP:        parseTableMap(h, r, b); break;
            case EV_WRITE_ROWS_V2:
            case EV_UPDATE_ROWS_V2:
            case EV_DELETE_ROWS_V2:   parseRowsV2(h, r, b); break;
            case EV_XID:              parseXid(h, r, b); break;
            case EV_ROTATE:           parseRotate(h, r, b); break;
            default:                  parseUnknown(h, b); break;
            }
            r.requireOk();   /* defensive: any latched reader error surfaces */
        }
    }

    /* ================================================================== */
    /* [7] Public API: header decode and whole-buffer parser.              */
    /* ================================================================== */
    public static Header parseHeader(byte[] data) {
        if (data == null || data.length < HEADER_SIZE) throw new BinlogError("truncated");
        return EventParser.readHeader(new ByteReader(data, 0, HEADER_SIZE));
    }

    public static String parseBuffer(byte[] data) {
        if (data == null || data.length < MAGIC_SIZE) throw new BinlogError("invalid");
        for (int i = 0; i < MAGIC_SIZE; i++)
            if (data[i] != MAGIC[i]) throw new BinlogError("invalid");

        SchemaRegistry registry = new SchemaRegistry();
        EventParser parser = new EventParser(registry);
        StringBuilder out = new StringBuilder();
        int pos = MAGIC_SIZE;

        while (pos < data.length) {
            if (data.length - pos < HEADER_SIZE) throw new BinlogError("truncated");
            Header h = EventParser.readHeader(new ByteReader(data, pos, HEADER_SIZE));
            long es = h.eventSize;
            if (es < HEADER_SIZE + CRC_SIZE || es > MAX_EVENT_SIZE
                    || es > data.length - pos)
                throw new BinlogError("truncated");
            int eventSize = (int) es;

            /* Every event in the controlled subset carries CRC32. */
            long stored = peekLe32(data, pos + eventSize - CRC_SIZE);
            long calc = crc32(data, pos, eventSize - CRC_SIZE);
            if (stored != calc) throw new BinlogError("checksum");

            int bodyStart = pos + HEADER_SIZE;
            int bodyLen = eventSize - HEADER_SIZE - CRC_SIZE;
            JsonBuilder b = new JsonBuilder(LINE_CAP);
            parser.dispatch(h, new ByteReader(data, bodyStart, bodyLen), b);
            if (b.overflow()) throw new BinlogError("invalid");

            out.append(b.toString()).append('\n');
            pos += eventSize;
        }
        return out.toString();
    }
}
