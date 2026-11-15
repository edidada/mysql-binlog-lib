/*
 * Phase 1 offline MySQL binlog parser (C# / .NET, no NuGet dependencies).
 *
 * CONTRACT: the public API in this file (ParseBuffer, ParseHeader, Crc32,
 * EventHeader, BinlogException) and the canonical JSONL emitted by
 * ParseBuffer are a cross-language contract: the other nine implementations,
 * fixtures/expected.jsonl and the CLI all rely on them. Do not change either
 * without a cross-language update.
 *
 * Layered structure (mirrors c/src/mysqlbinlog.c and docs/design.md section 4):
 *
 *   [1] ByteReader     bounds-checked little-endian primitives
 *   [2] CRC-32         IEEE / zlib checksum
 *   [3] Serializer     canonical JSONL builder (fixed key order, no spaces)
 *   [4] SchemaRegistry table_id -> TableSchema
 *   [5] RowDecoder     decode RowsEventV2 rows using a registered schema
 *   [6] EventParser    frame/verify/dispatch events -> one JSONL line each
 *   [7] Public API     ParseHeader / Crc32 / ParseBuffer
 */
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

    public static class Parser
    {
        /* ================================================================== */
        /* [0] Protocol constants (docs/design.md sections 2-3).             */
        /* ================================================================== */
        private const int HeaderSize = 19;
        private const int CrcSize = 4;
        private const int MagicSize = 4;
        private const int MaxCols = 64;
        private const int MaxTables = 64;
        private const long MaxEventSize = 256L * 1024 * 1024; // corrupt-size guard
        private const int LineCap = 16384;                     // max single JSONL line
        private const int StrCap = 2048;                      // max query / next_file
        private const int ValueCap = 512;                     // max VARCHAR value
        private const int NameCap = 128;                      // max db / table name
        private const int ServerVersionLen = 50;

        private const int TypeLong = 3;
        private const int TypeLonglong = 8;
        private const int TypeVarchar = 15;

        private const int EvQuery = 2;
        private const int EvRotate = 4;
        private const int EvFormatDesc = 15;
        private const int EvXid = 16;
        private const int EvTableMap = 19;
        private const int EvRowsQuery = 29;
        private const int EvWriteRowsV2 = 30;
        private const int EvUpdateRowsV2 = 31;
        private const int EvDeleteRowsV2 = 32;
        private const int EvGtid = 33;

        private static readonly byte[] Magic = { 0xFE, (byte)'b', (byte)'i', (byte)'n' };
        private const string Hex = "0123456789abcdef";

        /* ================================================================== */
        /* [1] ByteReader: every read is bounds-checked; Error latches.      */
        /* ================================================================== */
        private sealed class ByteReader
        {
            private readonly byte[] d;
            private readonly int len;
            private int pos;
            public string Error; // first failure code, latched

            public ByteReader(byte[] data, int start, int length)
            {
                d = data;
                len = start + length;
                pos = start;
                if (len > data.Length) Error = "truncated";
            }

            public int Pos { get { return pos; } set { pos = value; } }
            public int Len { get { return len; } }

            public int Rem() { return pos <= len ? len - pos : 0; }

            /// <summary>Overflow-safe "pos + n &lt;= len" test.</summary>
            public bool Can(int n)
            {
                return Error == null && n >= 0 && n <= len && pos <= len - n;
            }

            private void Fail(string code)
            {
                if (Error == null) Error = code;
            }

            public ulong Le(int n)
            {
                if (n > 8 || !Can(n)) { Fail("truncated"); return 0; }
                ulong v = 0;
                for (int i = 0; i < n; i++) v |= ((ulong)d[pos + i]) << (8 * i);
                pos += n;
                return v;
            }

            public byte[] Raw(int n)
            {
                if (!Can(n)) { Fail("truncated"); return new byte[0]; }
                var b = new byte[n];
                Array.Copy(d, pos, b, 0, n);
                pos += n;
                return b;
            }

            /// <summary>Read exactly n bytes as a bounded UTF-8 string, but always
            /// advance by n so framing stays aligned (mirrors rd_strn in C).</summary>
            public string Strn(int n, int cap)
            {
                if (cap == 0) return string.Empty;
                if (!Can(n)) { Fail("truncated"); return string.Empty; }
                int m = Math.Min(n, cap - 1);
                string s = Encoding.UTF8.GetString(d, pos, m);
                pos += n;
                return s;
            }

            public void Skip(int n)
            {
                if (!Can(n)) { Fail("truncated"); return; }
                pos += n;
            }

            /// <summary>MySQL length-encoded integer. 0xFB (NULL) and 0xFF
            /// (reserved) are not valid lengths where a length is required.</summary>
            public ulong Lenenc()
            {
                ulong b = Le(1);
                if (Error != null) return 0;
                if (b < 0xFB) return b;
                if (b == 0xFC) return Le(2);
                if (b == 0xFD) return Le(3);
                if (b == 0xFE) return Le(8);
                Fail("unsupported");
                return 0;
            }

            public byte LastByte() { return d[len - 1]; }
        }

        private static ulong PeekLe(byte[] p, int off, int n)
        {
            ulong v = 0;
            for (int i = 0; i < n; i++) v |= ((ulong)p[off + i]) << (8 * i);
            return v;
        }

        /* ================================================================== */
        /* [2] CRC-32 (IEEE 802.3 / zlib).                                    */
        /* Vector: Crc32("123456789") == 0xCBF43926.                         */
        /* ================================================================== */
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

        /* ================================================================== */
        /* [3] Serializer: bounded canonical JSONL builder.                  */
        /* ================================================================== */
        private sealed class Serializer
        {
            private readonly StringBuilder sb = new StringBuilder();
            private readonly int cap;
            public bool Overflow;

            public Serializer(int cap) { this.cap = cap; }

            private void Append(string s)
            {
                if (Overflow) return;
                if (sb.Length + s.Length > cap) { Overflow = true; return; }
                sb.Append(s);
            }

            public void Putc(char c) { Append(c.ToString()); }
            public void Puts(string s) { Append(s); }
            // A single object overload avoids ambiguous long/ulong conversions
            // for uint/int call sites; integers render culture-invariantly.
            public void UInt(object v)
            {
                Append(Convert.ToString(v, System.Globalization.CultureInfo.InvariantCulture));
            }

            /// <summary>Minimal JSON escaping: quotes, backslash, controls.</summary>
            public void JsonStr(string s)
            {
                Putc('"');
                foreach (char c in s)
                {
                    switch (c)
                    {
                        case '"': Puts("\\\""); break;
                        case '\\': Puts("\\\\"); break;
                        case '\n': Puts("\\n"); break;
                        case '\r': Puts("\\r"); break;
                        case '\t': Puts("\\t"); break;
                        default:
                            if (c < 0x20) Puts("\\u" + ((int)c).ToString("x4"));
                            else Putc(c);
                            break;
                    }
                }
                Putc('"');
            }

            public string Line() { return sb.ToString(); }
        }

        private static bool Bit(ulong v, int i) { return (v & (1UL << i)) != 0; }

        /* ================================================================== */
        /* [4] SchemaRegistry: table_id -> TableSchema, per-file lifetime.   */
        /* ================================================================== */
        private sealed class TableSchema
        {
            public ulong TableId;
            public string Db, Table;
            public int ColumnCount;
            public int[] ColumnTypes, VarcharLenBytes;
            public int NullableCount;
        }

        private sealed class SchemaRegistry
        {
            private readonly List<TableSchema> v = new List<TableSchema>();

            public void Put(TableSchema s) // replace existing, or add under cap
            {
                for (int i = 0; i < v.Count; i++)
                {
                    if (v[i].TableId == s.TableId) { v[i] = s; return; }
                }
                if (v.Count < MaxTables) v.Add(s);
            }

            public TableSchema Get(ulong id)
            {
                foreach (var s in v) if (s.TableId == id) return s;
                return null;
            }
        }

        /* ================================================================== */
        /* [5] RowDecoder: decode a row sequence against a TableSchema.      */
        /* ================================================================== */
        private static void Require(ByteReader r)
        {
            if (r.Error != null) throw new BinlogException(r.Error);
        }

        private static void DecodeValue(ByteReader r, TableSchema s, int col,
                                        bool isNull, Serializer b)
        {
            if (isNull) { b.Puts("null"); return; }
            switch (s.ColumnTypes[col])
            {
                case TypeLonglong:
                    b.UInt(unchecked((long)r.Le(8)));
                    break;
                case TypeLong:
                    b.UInt(unchecked((int)(uint)r.Le(4)));
                    break;
                case TypeVarchar:
                    {
                        int lb = s.VarcharLenBytes[col];
                        if (lb != 1 && lb != 2) throw new BinlogException("unsupported");
                        int slen = (int)r.Le(lb);
                        Require(r);
                        if (slen > ValueCap - 1) throw new BinlogException("unsupported");
                        b.JsonStr(r.Strn(slen, ValueCap));
                        break;
                    }
                default:
                    throw new BinlogException("unsupported");
            }
            Require(r);
        }

        private static void DecodeRows(ByteReader r, TableSchema s, ulong present, Serializer b)
        {
            int nbSize = (s.NullableCount + 7) / 8;
            if (nbSize > 8) throw new BinlogException("unsupported");
            b.Puts(",\"rows\":[");
            int rowno = 0;
            while (r.Rem() > 0 && r.Error == null)
            {
                ulong nullbm = r.Le(nbSize);
                Require(r);
                if (rowno > 0) b.Putc(',');
                b.Putc('[');
                bool first = true;
                for (int i = 0; i < s.ColumnCount; i++)
                {
                    if (!Bit(present, i)) continue;
                    if (!first) b.Putc(',');
                    first = false;
                    DecodeValue(r, s, i, Bit(nullbm, i), b);
                }
                b.Putc(']');
                rowno++;
            }
            b.Puts("]}");
            Require(r);
        }

        /* ================================================================== */
        /* [6] EventParser: header, framing, per-event dispatch.             */
        /* ================================================================== */
        public static EventHeader ParseHeader(byte[] data)
        {
            if (data == null || data.Length < HeaderSize)
                throw new BinlogException("truncated");
            var r = new ByteReader(data, 0, HeaderSize);
            var h = new EventHeader();
            h.Timestamp = (uint)r.Le(4);
            h.EventType = (byte)r.Le(1);
            h.ServerId = (uint)r.Le(4);
            h.EventSize = (uint)r.Le(4);
            h.NextPosition = (uint)r.Le(4);
            h.Flags = (ushort)r.Le(2);
            Require(r);
            return h;
        }

        private static string RowsName(int t)
        {
            if (t == EvWriteRowsV2) return "WRITE_ROWS_EVENT_V2";
            if (t == EvUpdateRowsV2) return "UPDATE_ROWS_EVENT_V2";
            if (t == EvDeleteRowsV2) return "DELETE_ROWS_EVENT_V2";
            return "ROWS_EVENT_V2";
        }

        private static void ParseFde(ByteReader r, EventHeader h, Serializer b)
        {
            if (r.Rem() < 2 + ServerVersionLen + 1) throw new BinlogException("truncated");
            ulong bv = r.Le(2);
            byte[] tmp = r.Raw(ServerVersionLen);
            int k = 0;
            while (k < tmp.Length && tmp[k] != 0) k++;
            string sv = Encoding.UTF8.GetString(tmp, 0, k);
            byte alg = r.LastByte();
            Require(r);
            b.Puts("{\"type\":\"FORMAT_DESCRIPTION_EVENT\",\"timestamp\":");
            b.UInt(h.Timestamp);
            b.Puts(",\"binlog_version\":");
            b.UInt(bv);
            b.Puts(",\"server_version\":");
            b.JsonStr(sv);
            b.Puts(",\"checksum_alg\":");
            b.UInt((ulong)alg);
            b.Putc('}');
        }

        private static void ParseGtid(ByteReader r, EventHeader h, Serializer b)
        {
            r.Le(1); // flags
            byte[] sid = r.Raw(16);
            ulong gno = r.Le(8);
            Require(r);
            var sh = new StringBuilder(32);
            foreach (byte x in sid) { sh.Append(Hex[x >> 4]); sh.Append(Hex[x & 0x0F]); }
            b.Puts("{\"type\":\"GTID_LOG_EVENT\",\"timestamp\":");
            b.UInt(h.Timestamp);
            b.Puts(",\"gno\":");
            b.UInt(gno);
            b.Puts(",\"sid\":");
            b.JsonStr(sh.ToString());
            b.Putc('}');
        }

        private static void ParseQuery(ByteReader r, EventHeader h, Serializer b)
        {
            r.Le(4); // thread_id
            r.Le(4); // exec_time
            int dbl = (int)r.Le(1);
            r.Le(2); // error_code
            int svl = (int)r.Le(2);
            r.Skip(svl); // status_vars
            string db = r.Strn(dbl, NameCap);
            r.Le(1); // trailing NUL after db
            int queryLen = r.Rem();
            string query = r.Strn(queryLen, StrCap);
            Require(r);
            b.Puts("{\"type\":\"QUERY_EVENT\",\"timestamp\":");
            b.UInt(h.Timestamp);
            b.Puts(",\"db\":");
            b.JsonStr(db);
            b.Puts(",\"query\":");
            b.JsonStr(query);
            b.Putc('}');
        }

        private static void ParseRowsQuery(ByteReader r, EventHeader h, Serializer b)
        {
            ulong ln = r.Lenenc();
            string q = r.Strn((int)ln, StrCap);
            Require(r);
            b.Puts("{\"type\":\"ROWS_QUERY_LOG_EVENT\",\"timestamp\":");
            b.UInt(h.Timestamp);
            b.Puts(",\"query\":");
            b.JsonStr(q);
            b.Putc('}');
        }

        private static void ParseTableMap(ByteReader r, EventHeader h,
                                          SchemaRegistry reg, Serializer b)
        {
            var s = new TableSchema();
            s.TableId = r.Le(6);
            r.Le(2); // flags
            int dbl = (int)r.Le(1);
            s.Db = r.Strn(dbl, NameCap);
            r.Le(1); // NUL
            int tbl = (int)r.Le(1);
            s.Table = r.Strn(tbl, NameCap);
            r.Le(1); // NUL
            int cc = (int)r.Lenenc();
            Require(r);
            if (cc == 0 || cc > MaxCols) throw new BinlogException("unsupported");
            s.ColumnCount = cc;
            s.ColumnTypes = new int[cc];
            s.VarcharLenBytes = new int[cc];
            for (int i = 0; i < cc; i++) s.ColumnTypes[i] = (int)r.Le(1);

            ulong mdLen = r.Lenenc();
            int mdStart = r.Pos;
            if (r.Error != null || mdLen > (ulong)r.Len || mdStart > r.Len - (int)mdLen)
                throw new BinlogException("truncated");
            for (int i = 0; i < cc; i++)
            {
                if (s.ColumnTypes[i] == TypeVarchar)
                {
                    if (r.Pos + 2 > mdStart + (int)mdLen) throw new BinlogException("truncated");
                    ulong mx = r.Le(2);
                    s.VarcharLenBytes[i] = mx > 255 ? 2 : 1;
                }
            }
            r.Pos = mdStart + (int)mdLen; // skip any extra metadata

            int nb = (cc + 7) / 8;
            if (nb > 8) throw new BinlogException("unsupported");
            ulong nullbm = r.Le(nb);
            int nullable = 0;
            for (int i = 0; i < cc; i++) if (Bit(nullbm, i)) nullable++;
            s.NullableCount = nullable;
            Require(r);
            reg.Put(s);

            b.Puts("{\"type\":\"TABLE_MAP_EVENT\",\"timestamp\":");
            b.UInt(h.Timestamp);
            b.Puts(",\"table_id\":");
            b.UInt(s.TableId);
            b.Puts(",\"db\":");
            b.JsonStr(s.Db);
            b.Puts(",\"table\":");
            b.JsonStr(s.Table);
            b.Puts(",\"column_count\":");
            b.UInt((ulong)cc);
            b.Puts(",\"column_types\":[");
            for (int i = 0; i < cc; i++)
            {
                if (i > 0) b.Putc(',');
                b.UInt((ulong)s.ColumnTypes[i]);
            }
            b.Puts("]}");
        }

        private static void ParseRowsV2(ByteReader r, EventHeader h,
                                        SchemaRegistry reg, Serializer b)
        {
            ulong tid = r.Le(6);
            r.Le(2); // flags
            ulong extraLen = r.Le(2); // includes its own 2 bytes
            if (extraLen < 2) throw new BinlogException("unsupported");
            r.Skip((int)extraLen - 2);
            int cc = (int)r.Lenenc();
            Require(r);
            if (cc == 0 || cc > MaxCols) throw new BinlogException("unsupported");
            int bmSize = (cc + 7) / 8;
            if (bmSize > 8) throw new BinlogException("unsupported");
            ulong present = r.Le(bmSize);
            if (h.EventType == EvUpdateRowsV2) r.Le(bmSize); // before/after bitmap
            Require(r);
            TableSchema s = reg.Get(tid);
            if (s == null) throw new BinlogException("no_schema");

            b.Puts("{\"type\":\"");
            b.Puts(RowsName(h.EventType));
            b.Puts("\",\"timestamp\":");
            b.UInt(h.Timestamp);
            b.Puts(",\"table_id\":");
            b.UInt(tid);
            b.Puts(",\"db\":");
            b.JsonStr(s.Db);
            b.Puts(",\"table\":");
            b.JsonStr(s.Table);
            DecodeRows(r, s, present, b);
        }

        private static void ParseXid(ByteReader r, EventHeader h, Serializer b)
        {
            ulong xid = r.Le(8);
            Require(r);
            b.Puts("{\"type\":\"XID_EVENT\",\"timestamp\":");
            b.UInt(h.Timestamp);
            b.Puts(",\"xid\":");
            b.UInt(xid);
            b.Putc('}');
        }

        private static void ParseRotate(ByteReader r, EventHeader h, Serializer b)
        {
            ulong position = r.Le(8);
            int nfLen = r.Rem();
            string nf = r.Strn(nfLen, StrCap);
            Require(r);
            b.Puts("{\"type\":\"ROTATE_EVENT\",\"timestamp\":");
            b.UInt(h.Timestamp);
            b.Puts(",\"position\":");
            b.UInt(position);
            b.Puts(",\"next_file\":");
            b.JsonStr(nf);
            b.Putc('}');
        }

        private static void ParseUnknown(EventHeader h, Serializer b)
        {
            b.Puts("{\"type\":\"UNKNOWN\",\"timestamp\":");
            b.UInt(h.Timestamp);
            b.Puts(",\"type_id\":");
            b.UInt((ulong)h.EventType);
            b.Puts(",\"event_size\":");
            b.UInt(h.EventSize);
            b.Putc('}');
        }

        /// <summary>Dispatch one verified event body to its named handler.</summary>
        private static void DispatchEvent(EventHeader h, byte[] data, int bodyStart,
                                          int bodyLen, SchemaRegistry reg, Serializer b)
        {
            var r = new ByteReader(data, bodyStart, bodyLen);
            switch (h.EventType)
            {
                case EvFormatDesc: ParseFde(r, h, b); break;
                case EvGtid: ParseGtid(r, h, b); break;
                case EvQuery: ParseQuery(r, h, b); break;
                case EvRowsQuery: ParseRowsQuery(r, h, b); break;
                case EvTableMap: ParseTableMap(r, h, reg, b); break;
                case EvWriteRowsV2:
                case EvUpdateRowsV2:
                case EvDeleteRowsV2: ParseRowsV2(r, h, reg, b); break;
                case EvXid: ParseXid(r, h, b); break;
                case EvRotate: ParseRotate(r, h, b); break;
                default: ParseUnknown(h, b); break; // UNKNOWN -> stable skip
            }
        }

        /* ================================================================== */
        /* [7] Public API: whole-buffer parser.                              */
        /* ================================================================== */
        public static string ParseBuffer(byte[] data)
        {
            if (data == null || data.Length < MagicSize) throw new BinlogException("invalid");
            for (int i = 0; i < MagicSize; i++)
                if (data[i] != Magic[i]) throw new BinlogException("invalid");

            var reg = new SchemaRegistry();
            var outSb = new StringBuilder();
            int pos = MagicSize;
            while (pos < data.Length)
            {
                if (data.Length - pos < HeaderSize) throw new BinlogException("truncated");
                var hdr = new byte[HeaderSize];
                Array.Copy(data, pos, hdr, 0, HeaderSize);
                EventHeader h = ParseHeader(hdr);
                long es = h.EventSize;
                if (es < HeaderSize + CrcSize || es > MaxEventSize || es > data.Length - pos)
                    throw new BinlogException("truncated");
                int eventSize = (int)es;

                // Every event in the controlled subset carries CRC32 (FDE
                // declares checksum_alg=1), so verify unconditionally.
                ulong stored = PeekLe(data, pos + eventSize - CrcSize, CrcSize);
                uint calc = Crc32(data, pos, eventSize - CrcSize);
                if (stored != calc) throw new BinlogException("checksum");

                int bodyStart = pos + HeaderSize;
                int bodyLen = eventSize - HeaderSize - CrcSize;
                var b = new Serializer(LineCap);
                DispatchEvent(h, data, bodyStart, bodyLen, reg, b);
                if (b.Overflow) throw new BinlogException("invalid");
                outSb.Append(b.Line()).Append('\n');
                pos += eventSize;
            }
            return outSb.ToString();
        }
    }
}
