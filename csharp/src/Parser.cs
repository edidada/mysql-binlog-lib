using System;
using System.Collections.Generic;
using System.Text;

namespace MysqlBinlog
{
    public sealed class BinlogException : Exception
    {
        public string Code { get; }
        public BinlogException(string code) : base(code) { Code = code; }
    }

    public struct EventHeader
    {
        public uint Timestamp;
        public byte EventType;
        public uint ServerId;
        public uint EventSize;
        public uint NextPosition;
        public ushort Flags;
    }

    /// <summary>Phase 1 offline MySQL binlog parser (.NET only, no NuGet deps).</summary>
    public static class Parser
    {
        private sealed class Reader
        {
            public readonly byte[] D;
            public int Pos;
            public Reader(byte[] d) { D = d; }
            public int Rem() { return D.Length - Pos; }
            public ulong Le(int n)
            {
                if (n < 0 || n > 8 || Pos + n > D.Length) throw new BinlogException("truncated");
                ulong v = 0;
                for (int i = 0; i < n; i++) v |= ((ulong)D[Pos + i]) << (8 * i);
                Pos += n;
                return v;
            }
            public byte[] Raw(int n)
            {
                if (n < 0 || Pos + n > D.Length) throw new BinlogException("truncated");
                var b = new byte[n];
                Array.Copy(D, Pos, b, 0, n);
                Pos += n;
                return b;
            }
            public string Text(int n) { return Encoding.UTF8.GetString(Raw(n)); }
            public void Skip(int n)
            {
                if (n < 0 || Pos + n > D.Length) throw new BinlogException("truncated");
                Pos += n;
            }
            public ulong Lenenc()
            {
                ulong b = Le(1);
                if (b < 0xFB) return b;
                if (b == 0xFB) return 0;
                if (b == 0xFC) return Le(2);
                if (b == 0xFD) return Le(3);
                if (b == 0xFE) return Le(8);
                return 0;
            }
        }

        private sealed class Schema
        {
            public ulong TableId;
            public string Db, Table;
            public int Cc;
            public int[] Types, Vlen;
            public int Nullable;
        }

        private static ulong Le(byte[] d, int off, int n)
        {
            ulong v = 0;
            for (int i = 0; i < n; i++) v |= ((ulong)d[off + i]) << (8 * i);
            return v;
        }

        /// <summary>CRC-32 (IEEE / zlib), implemented bitwise.</summary>
        public static uint Crc32(byte[] d, int off, int len)
        {
            uint crc = 0xFFFFFFFF;
            for (int i = off; i < off + len; i++)
            {
                crc ^= d[i];
                for (int k = 0; k < 8; k++)
                {
                    uint mask = 0u - (crc & 1u);
                    crc = (crc >> 1) ^ (0xEDB88320u & mask);
                }
            }
            return ~crc;
        }

        public static EventHeader ParseHeader(byte[] data)
        {
            if (data.Length < 19) throw new BinlogException("truncated");
            var r = new Reader(data);
            var h = new EventHeader();
            h.Timestamp = (uint)r.Le(4);
            h.EventType = (byte)r.Le(1);
            h.ServerId = (uint)r.Le(4);
            h.EventSize = (uint)r.Le(4);
            h.NextPosition = (uint)r.Le(4);
            h.Flags = (ushort)r.Le(2);
            return h;
        }

        private static void JStr(StringBuilder b, string s)
        {
            b.Append('"');
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': b.Append("\\\""); break;
                    case '\\': b.Append("\\\\"); break;
                    case '\n': b.Append("\\n"); break;
                    case '\r': b.Append("\\r"); break;
                    case '\t': b.Append("\\t"); break;
                    default:
                        if (c < 0x20) b.Append("\\u").Append(((int)c).ToString("x4"));
                        else b.Append(c);
                        break;
                }
            }
            b.Append('"');
        }

        private static string RowsName(int t)
        {
            if (t == 30) return "WRITE_ROWS_EVENT_V2";
            if (t == 31) return "UPDATE_ROWS_EVENT_V2";
            if (t == 32) return "DELETE_ROWS_EVENT_V2";
            return "ROWS_EVENT_V2";
        }

        public static string ParseBuffer(byte[] data)
        {
            if (data.Length < 4) throw new BinlogException("invalid");
            if (!(data[0] == 0xFE && data[1] == (byte)'b' && data[2] == (byte)'i' && data[3] == (byte)'n'))
                throw new BinlogException("invalid");

            var reg = new Dictionary<ulong, Schema>();
            var outSb = new StringBuilder();
            int pos = 4; // skip magic
            while (pos < data.Length)
            {
                if (pos + 19 > data.Length) throw new BinlogException("truncated");
                var hdr = new byte[19];
                Array.Copy(data, pos, hdr, 0, 19);
                EventHeader h = ParseHeader(hdr);
                long es = h.EventSize;
                if (es < 23 || pos + es > data.Length) throw new BinlogException("truncated");
                var full = new byte[(int)es];
                Array.Copy(data, pos, full, 0, (int)es);
                ulong stored = Le(full, (int)es - 4, 4);
                uint calc = Crc32(full, 0, (int)es - 4);
                if (stored != calc) throw new BinlogException("checksum");
                var body = new byte[(int)es - 23];
                Array.Copy(full, 19, body, 0, body.Length);
                var r = new Reader(body);
                var b = new StringBuilder();
                int t = h.EventType;
                uint ts = h.Timestamp;

                switch (t)
                {
                    case 15: // FORMAT_DESCRIPTION_EVENT
                    {
                        ulong bv = r.Le(2);
                        byte[] tmp = r.Raw(50);
                        int k = 0;
                        while (k < 50 && tmp[k] != 0) k++;
                        string sv = Encoding.UTF8.GetString(tmp, 0, k);
                        ulong alg = body[body.Length - 1];
                        b.Append("{\"type\":\"FORMAT_DESCRIPTION_EVENT\",\"timestamp\":").Append(ts)
                         .Append(",\"binlog_version\":").Append(bv).Append(",\"server_version\":");
                        JStr(b, sv);
                        b.Append(",\"checksum_alg\":").Append(alg).Append('}');
                        break;
                    }
                    case 33: // GTID_LOG_EVENT
                    {
                        r.Le(1); // flags
                        byte[] sid = r.Raw(16);
                        ulong gno = r.Le(8);
                        var sh = new StringBuilder();
                        foreach (byte x in sid) sh.Append(x.ToString("x2"));
                        b.Append("{\"type\":\"GTID_LOG_EVENT\",\"timestamp\":").Append(ts)
                         .Append(",\"gno\":").Append(gno).Append(",\"sid\":");
                        JStr(b, sh.ToString());
                        b.Append('}');
                        break;
                    }
                    case 2: // QUERY_EVENT
                    {
                        r.Le(4); // thread_id
                        r.Le(4); // exec_time
                        int dbl = (int)r.Le(1);
                        r.Le(2);  // error_code
                        int svl = (int)r.Le(2);
                        r.Skip(svl);
                        string db = r.Text(dbl);
                        r.Le(1); // trailing NUL
                        string query = r.Text(r.Rem());
                        b.Append("{\"type\":\"QUERY_EVENT\",\"timestamp\":").Append(ts).Append(",\"db\":");
                        JStr(b, db);
                        b.Append(",\"query\":");
                        JStr(b, query);
                        b.Append('}');
                        break;
                    }
                    case 29: // ROWS_QUERY_LOG_EVENT
                    {
                        int ln = (int)r.Lenenc();
                        string q = r.Text(ln);
                        b.Append("{\"type\":\"ROWS_QUERY_LOG_EVENT\",\"timestamp\":").Append(ts)
                         .Append(",\"query\":");
                        JStr(b, q);
                        b.Append('}');
                        break;
                    }
                    case 19: // TABLE_MAP_EVENT
                    {
                        var s = new Schema();
                        s.TableId = r.Le(6);
                        r.Le(2); // flags
                        int dbl = (int)r.Le(1);
                        s.Db = r.Text(dbl);
                        r.Le(1); // NUL
                        int tbl = (int)r.Le(1);
                        s.Table = r.Text(tbl);
                        r.Le(1); // NUL
                        s.Cc = (int)r.Lenenc();
                        s.Types = new int[s.Cc];
                        s.Vlen = new int[s.Cc];
                        for (int i = 0; i < s.Cc; i++) s.Types[i] = (int)r.Le(1);
                        ulong mdlen = r.Lenenc();
                        int mdstart = r.Pos;
                        for (int i = 0; i < s.Cc; i++)
                        {
                            if (s.Types[i] == 15)
                            {
                                ulong mx = r.Le(2);
                                s.Vlen[i] = (mx > 255) ? 2 : 1;
                            }
                        }
                        r.Pos = mdstart + (int)mdlen;
                        int nb = (s.Cc + 7) / 8;
                        ulong nullbm = r.Le(nb);
                        int nullable = 0;
                        for (int i = 0; i < s.Cc; i++) if ((nullbm & (1UL << i)) != 0) nullable++;
                        s.Nullable = nullable;
                        reg[s.TableId] = s;

                        b.Append("{\"type\":\"TABLE_MAP_EVENT\",\"timestamp\":").Append(ts)
                         .Append(",\"table_id\":").Append(s.TableId).Append(",\"db\":");
                        JStr(b, s.Db);
                        b.Append(",\"table\":");
                        JStr(b, s.Table);
                        b.Append(",\"column_count\":").Append(s.Cc).Append(",\"column_types\":[");
                        for (int i = 0; i < s.Cc; i++)
                        {
                            if (i > 0) b.Append(',');
                            b.Append(s.Types[i]);
                        }
                        b.Append("]}");
                        break;
                    }
                    case 30: case 31: case 32: // ROWS_EVENT_V2
                    {
                        ulong tid = r.Le(6);
                        r.Le(2); // flags
                        ulong el = r.Le(2);
                        if (el >= 2) r.Skip((int)el - 2);
                        int cc = (int)r.Lenenc();
                        int bm = (cc + 7) / 8;
                        ulong present1 = r.Le(bm);
                        if (t == 31) r.Le(bm); // bitmap2, equal
                        Schema s;
                        if (!reg.TryGetValue(tid, out s)) throw new BinlogException("no_schema");
                        int nbs = (s.Nullable + 7) / 8;

                        b.Append("{\"type\":\"").Append(RowsName(t))
                         .Append("\",\"timestamp\":").Append(ts)
                         .Append(",\"table_id\":").Append(tid).Append(",\"db\":");
                        JStr(b, s.Db);
                        b.Append(",\"table\":");
                        JStr(b, s.Table);
                        b.Append(",\"rows\":[");
                        int rowno = 0;
                        while (r.Rem() > 0)
                        {
                            ulong nullbm = r.Le(nbs);
                            if (rowno > 0) b.Append(',');
                            b.Append('[');
                            bool first = true;
                            for (int i = 0; i < s.Cc; i++)
                            {
                                if ((present1 & (1UL << i)) == 0) continue;
                                if (!first) b.Append(',');
                                first = false;
                                if ((nullbm & (1UL << i)) != 0) { b.Append("null"); continue; }
                                int ct = s.Types[i];
                                if (ct == 8) b.Append(r.Le(8));
                                else if (ct == 3) b.Append(r.Le(4));
                                else if (ct == 15)
                                {
                                    int lb = s.Vlen[i] == 0 ? 1 : s.Vlen[i];
                                    int slen = (int)r.Le(lb);
                                    JStr(b, r.Text(slen));
                                }
                                else throw new BinlogException("unsupported");
                            }
                            b.Append(']');
                            rowno++;
                        }
                        b.Append("]}");
                        break;
                    }
                    case 16: // XID_EVENT
                    {
                        ulong xid = r.Le(8);
                        b.Append("{\"type\":\"XID_EVENT\",\"timestamp\":").Append(ts)
                         .Append(",\"xid\":").Append(xid).Append('}');
                        break;
                    }
                    case 4: // ROTATE_EVENT
                    {
                        ulong position = r.Le(8);
                        string nf = r.Text(r.Rem());
                        b.Append("{\"type\":\"ROTATE_EVENT\",\"timestamp\":").Append(ts)
                         .Append(",\"position\":").Append(position).Append(",\"next_file\":");
                        JStr(b, nf);
                        b.Append('}');
                        break;
                    }
                    default: // UNKNOWN -> safe skip
                    {
                        b.Append("{\"type\":\"UNKNOWN\",\"timestamp\":").Append(ts)
                         .Append(",\"type_id\":").Append(t)
                         .Append(",\"event_size\":").Append(es).Append('}');
                        break;
                    }
                }
                outSb.Append(b).Append('\n');
                pos += (int)es;
            }
            return outSb.ToString();
        }
    }
}
