using System;
using System.IO;
using System.Text;
using MysqlBinlog;

namespace MysqlBinlog.Tests
{
    /// <summary>Self-contained unit + golden tests (no test framework / NuGet).</summary>
    /// Mirrors c/tests/test_parser.c: CRC vector, header fields, framing/CRC/
    /// truncation error paths and the byte-exact cross-language golden output.
    public static class Program
    {
        private static int failures = 0;

        private static void Check(bool cond, string msg)
        {
            if (!cond) { Console.Error.WriteLine("FAIL: " + msg); failures++; }
        }

        private static void PutLe(byte[] p, int off, ulong v, int n)
        {
            for (int i = 0; i < n; i++) p[off + i] = (byte)(v >> (8 * i));
        }

        private static readonly byte[] Magic = { 0xFE, (byte)'b', (byte)'i', (byte)'n' };

        /// <summary>Frame magic + one event (header + body + CRC32).</summary>
        private static byte[] BuildEvent(byte eventType, uint? crcOverride, byte[] body)
        {
            int es = 19 + body.Length + 4;
            var buf = new byte[4 + es];
            Array.Copy(Magic, 0, buf, 0, 4);
            PutLe(buf, 4, 1, 4);            // timestamp
            buf[8] = eventType;
            PutLe(buf, 9, 1, 4);            // server_id
            PutLe(buf, 13, (ulong)es, 4);   // event_size
            PutLe(buf, 17, (ulong)(es + 4), 4); // next_position
            PutLe(buf, 21, 0, 2);           // flags
            Array.Copy(body, 0, buf, 23, body.Length);
            uint c = crcOverride ?? Parser.Crc32(buf, 4, 19 + body.Length);
            PutLe(buf, buf.Length - 4, c, 4);
            return buf;
        }

        private static void ExpectError(string expected, byte[] data, string msg)
        {
            try { Parser.ParseBuffer(data); Check(false, msg + " (no exception)"); }
            catch (BinlogException e) { Check(e.Code == expected, msg + " (expected " + expected + ", got " + e.Code + ")"); }
        }

        public static int Main()
        {
            Check(Parser.Crc32(Encoding.ASCII.GetBytes("123456789"), 0, 9) == 0xCBF43926,
                  "crc32 vector");

            var h = new byte[19];
            PutLe(h, 0, 1700000000UL, 4);
            h[4] = 15;
            PutLe(h, 5, 1, 4);
            PutLe(h, 9, 119, 4);
            PutLe(h, 13, 123, 4);
            PutLe(h, 17, 0, 2);
            var hd = Parser.ParseHeader(h);
            Check(hd.Timestamp == 1700000000, "timestamp");
            Check(hd.EventType == 15, "eventType");
            Check(hd.ServerId == 1, "serverId");
            Check(hd.EventSize == 119, "eventSize");
            Check(hd.NextPosition == 123, "nextPosition");
            Check(hd.Flags == 0, "flags");

            ExpectError("invalid", new byte[10], "short buffer with bad magic");
            try { Parser.ParseHeader(new byte[10]); Check(false, "truncated header should throw"); }
            catch (BinlogException e) { Check(e.Code == "truncated", "truncated code"); }

            ExpectError("invalid", new byte[4], "bad magic");
            ExpectError("invalid", new byte[3], "short buffer");
            Check(Parser.ParseBuffer(Magic).Length == 0, "lone magic yields empty output");

            byte[] unknown = BuildEvent(99, null, new byte[] { 1, 2, 3 });
            Check(Parser.ParseBuffer(unknown) ==
                  "{\"type\":\"UNKNOWN\",\"timestamp\":1,\"type_id\":99,\"event_size\":26}\n",
                  "valid UNKNOWN event output");

            ExpectError("checksum", BuildEvent(99, 0, new byte[] { 1, 2, 3 }), "crc mismatch");

            var trailing = new byte[unknown.Length + 3];
            Array.Copy(unknown, trailing, unknown.Length);
            trailing[unknown.Length] = 1; trailing[unknown.Length + 1] = 2; trailing[unknown.Length + 2] = 3;
            ExpectError("truncated", trailing, "trailing partial header");

            var tooSmall = BuildEvent(99, null, new byte[0]);
            PutLe(tooSmall, 4 + 9, 10, 4);
            PutLe(tooSmall, tooSmall.Length - 4, Parser.Crc32(tooSmall, 4, tooSmall.Length - 8), 4);
            ExpectError("truncated", tooSmall, "undersized event_size");

            var oversized = BuildEvent(99, null, new byte[0]);
            PutLe(oversized, 4 + 9, 0xFFFFFFFFUL, 4);
            PutLe(oversized, oversized.Length - 4, Parser.Crc32(oversized, 4, oversized.Length - 8), 4);
            ExpectError("truncated", oversized, "oversized event_size");

            byte[] data = File.ReadAllBytes("fixtures/demo.bin");
            string expected = File.ReadAllText("fixtures/expected.jsonl");
            Check(Parser.ParseBuffer(data) == expected, "golden fixture");

            if (failures > 0) { Console.Error.WriteLine(failures + " failures"); return 1; }
            Console.WriteLine("csharp unit tests ok");
            return 0;
        }
    }
}
