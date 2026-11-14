package mysqlbinlog;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashMap;

/** Phase 1 offline MySQL binlog parser (JDK only, no third-party deps). */
public final class Parser {

    private Parser() {}

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

    private static final class Reader {
        final byte[] d;
        int pos;
        Reader(byte[] d) { this.d = d; }
        int rem() { return d.length - pos; }
        long le(int n) {
            if (n < 0 || n > 8 || pos + n > d.length) throw new BinlogError("truncated");
            long v = 0;
            for (int i = 0; i < n; i++) v |= ((long) (d[pos + i] & 0xFF)) << (8 * i);
            pos += n;
            return v;
        }
        byte[] raw(int n) {
            if (n < 0 || pos + n > d.length) throw new BinlogError("truncated");
            byte[] b = Arrays.copyOfRange(d, pos, pos + n);
            pos += n;
            return b;
        }
        String text(int n) { return new String(raw(n), StandardCharsets.UTF_8); }
        void skip(int n) {
            if (n < 0 || pos + n > d.length) throw new BinlogError("truncated");
            pos += n;
        }
        long lenenc() {
            long b = le(1);
            if (b < 0xFB) return b;
            if (b == 0xFB) return 0;
            if (b == 0xFC) return le(2);
            if (b == 0xFD) return le(3);
            if (b == 0xFE) return le(8);
            return 0;
        }
    }

    private static final class Schema {
        long tableId;
        String db, table;
        int cc;
        int[] types, vlen;
        int nullable;
    }

    private static long le(byte[] d, int off, int n) {
        long v = 0;
        for (int i = 0; i < n; i++) v |= ((long) (d[off + i] & 0xFF)) << (8 * i);
        return v;
    }

    /** CRC-32 (IEEE / zlib), implemented bitwise. */
    public static long crc32(byte[] data, int off, int len) {
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

    public static Header parseHeader(byte[] data) {
        if (data.length < 19) throw new BinlogError("truncated");
        Reader r = new Reader(data);
        Header h = new Header();
        h.timestamp = r.le(4);
        h.eventType = (int) r.le(1);
        h.serverId = r.le(4);
        h.eventSize = r.le(4);
        h.nextPosition = r.le(4);
        h.flags = (int) r.le(2);
        return h;
    }

    private static void jstr(StringBuilder b, String s) {
        b.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':  b.append("\\\""); break;
                case '\\': b.append("\\\\"); break;
                case '\n': b.append("\\n"); break;
                case '\r': b.append("\\r"); break;
                case '\t': b.append("\\t"); break;
                default:
                    if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
                    else b.append(c);
            }
        }
        b.append('"');
    }

    private static String rowsName(int t) {
        if (t == 30) return "WRITE_ROWS_EVENT_V2";
        if (t == 31) return "UPDATE_ROWS_EVENT_V2";
        if (t == 32) return "DELETE_ROWS_EVENT_V2";
        return "ROWS_EVENT_V2";
    }

    public static String parseBuffer(byte[] data) {
        if (data.length < 4) throw new BinlogError("invalid");
        if (!((data[0] & 0xFF) == 0xFE && data[1] == 'b' && data[2] == 'i' && data[3] == 'n'))
            throw new BinlogError("invalid");

        HashMap<Long, Schema> reg = new HashMap<>();
        StringBuilder out = new StringBuilder();
        int pos = 4; // skip magic
        while (pos < data.length) {
            if (pos + 19 > data.length) throw new BinlogError("truncated");
            Header h = parseHeader(Arrays.copyOfRange(data, pos, pos + 19));
            long es = h.eventSize;
            if (es < 23 || pos + es > data.length) throw new BinlogError("truncated");
            byte[] full = Arrays.copyOfRange(data, pos, pos + (int) es);
            long stored = le(full, (int) es - 4, 4);
            long calc = crc32(full, 0, (int) es - 4);
            if (stored != calc) throw new BinlogError("checksum");
            byte[] body = Arrays.copyOfRange(full, 19, (int) es - 4);
            Reader r = new Reader(body);
            StringBuilder b = new StringBuilder();
            int t = h.eventType;
            long ts = h.timestamp;

            switch (t) {
            case 15: { // FORMAT_DESCRIPTION_EVENT
                long bv = r.le(2);
                byte[] tmp = r.raw(50);
                int k = 0;
                while (k < 50 && tmp[k] != 0) k++;
                String sv = new String(tmp, 0, k, StandardCharsets.UTF_8);
                long alg = body[body.length - 1] & 0xFF;
                b.append("{\"type\":\"FORMAT_DESCRIPTION_EVENT\",\"timestamp\":").append(ts)
                 .append(",\"binlog_version\":").append(bv)
                 .append(",\"server_version\":");
                jstr(b, sv);
                b.append(",\"checksum_alg\":").append(alg).append('}');
                break;
            }
            case 33: { // GTID_LOG_EVENT
                r.le(1); // flags
                byte[] sid = r.raw(16);
                long gno = r.le(8);
                StringBuilder sh = new StringBuilder();
                for (byte x : sid) sh.append(String.format("%02x", x & 0xFF));
                b.append("{\"type\":\"GTID_LOG_EVENT\",\"timestamp\":").append(ts)
                 .append(",\"gno\":").append(gno).append(",\"sid\":");
                jstr(b, sh.toString());
                b.append('}');
                break;
            }
            case 2: { // QUERY_EVENT
                r.le(4); // thread_id
                r.le(4); // exec_time
                int dbl = (int) r.le(1);
                r.le(2);  // error_code
                int svl = (int) r.le(2);
                r.skip(svl);
                String db = r.text(dbl);
                r.le(1); // trailing NUL
                String query = r.text(r.rem());
                b.append("{\"type\":\"QUERY_EVENT\",\"timestamp\":").append(ts).append(",\"db\":");
                jstr(b, db);
                b.append(",\"query\":");
                jstr(b, query);
                b.append('}');
                break;
            }
            case 29: { // ROWS_QUERY_LOG_EVENT
                int ln = (int) r.lenenc();
                String q = r.text(ln);
                b.append("{\"type\":\"ROWS_QUERY_LOG_EVENT\",\"timestamp\":").append(ts)
                 .append(",\"query\":");
                jstr(b, q);
                b.append('}');
                break;
            }
            case 19: { // TABLE_MAP_EVENT
                Schema s = new Schema();
                s.tableId = r.le(6);
                r.le(2); // flags
                int dbl = (int) r.le(1);
                s.db = r.text(dbl);
                r.le(1); // NUL
                int tbl = (int) r.le(1);
                s.table = r.text(tbl);
                r.le(1); // NUL
                s.cc = (int) r.lenenc();
                s.types = new int[s.cc];
                s.vlen = new int[s.cc];
                for (int i = 0; i < s.cc; i++) s.types[i] = (int) r.le(1);
                long mdlen = r.lenenc();
                int mdstart = r.pos;
                for (int i = 0; i < s.cc; i++) {
                    if (s.types[i] == 15) {
                        long mx = r.le(2);
                        s.vlen[i] = (mx > 255) ? 2 : 1;
                    }
                }
                r.pos = mdstart + (int) mdlen;
                int nb = (s.cc + 7) / 8;
                long nullbm = r.le(nb);
                int nullable = 0;
                for (int i = 0; i < s.cc; i++) if ((nullbm & (1L << i)) != 0) nullable++;
                s.nullable = nullable;
                reg.put(s.tableId, s);

                b.append("{\"type\":\"TABLE_MAP_EVENT\",\"timestamp\":").append(ts)
                 .append(",\"table_id\":").append(s.tableId).append(",\"db\":");
                jstr(b, s.db);
                b.append(",\"table\":");
                jstr(b, s.table);
                b.append(",\"column_count\":").append(s.cc).append(",\"column_types\":[");
                for (int i = 0; i < s.cc; i++) {
                    if (i > 0) b.append(',');
                    b.append(s.types[i]);
                }
                b.append("]}");
                break;
            }
            case 30: case 31: case 32: { // ROWS_EVENT_V2
                long tid = r.le(6);
                r.le(2); // flags
                long el = r.le(2);
                if (el >= 2) r.skip((int) el - 2);
                int cc = (int) r.lenenc();
                int bm = (cc + 7) / 8;
                long present1 = r.le(bm);
                if (t == 31) r.le(bm); // bitmap2, equal
                Schema s = reg.get(tid);
                if (s == null) throw new BinlogError("no_schema");
                int nbs = (s.nullable + 7) / 8;

                b.append("{\"type\":\"").append(rowsName(t))
                 .append("\",\"timestamp\":").append(ts)
                 .append(",\"table_id\":").append(tid).append(",\"db\":");
                jstr(b, s.db);
                b.append(",\"table\":");
                jstr(b, s.table);
                b.append(",\"rows\":[");
                int rowno = 0;
                while (r.rem() > 0) {
                    long nullbm = r.le(nbs);
                    if (rowno > 0) b.append(',');
                    b.append('[');
                    boolean first = true;
                    for (int i = 0; i < s.cc; i++) {
                        if ((present1 & (1L << i)) == 0) continue;
                        if (!first) b.append(',');
                        first = false;
                        if ((nullbm & (1L << i)) != 0) { b.append("null"); continue; }
                        int ct = s.types[i];
                        if (ct == 8) b.append(r.le(8));
                        else if (ct == 3) b.append(r.le(4));
                        else if (ct == 15) {
                            int lb = s.vlen[i] == 0 ? 1 : s.vlen[i];
                            int slen = (int) r.le(lb);
                            jstr(b, r.text(slen));
                        } else throw new BinlogError("unsupported");
                    }
                    b.append(']');
                    rowno++;
                }
                b.append("]}");
                break;
            }
            case 16: { // XID_EVENT
                long xid = r.le(8);
                b.append("{\"type\":\"XID_EVENT\",\"timestamp\":").append(ts)
                 .append(",\"xid\":").append(xid).append('}');
                break;
            }
            case 4: { // ROTATE_EVENT
                long position = r.le(8);
                String nf = r.text(r.rem());
                b.append("{\"type\":\"ROTATE_EVENT\",\"timestamp\":").append(ts)
                 .append(",\"position\":").append(position).append(",\"next_file\":");
                jstr(b, nf);
                b.append('}');
                break;
            }
            default: { // UNKNOWN -> safe skip
                b.append("{\"type\":\"UNKNOWN\",\"timestamp\":").append(ts)
                 .append(",\"type_id\":").append(t)
                 .append(",\"event_size\":").append(es).append('}');
                break;
            }
            }
            out.append(b).append('\n');
            pos += (int) es;
        }
        return out.toString();
    }
}
