using System;
using System.IO;
using System.Text;
using MysqlBinlog;

namespace MysqlBinlog.Tests
{
    /// <summary>Self-contained unit + golden tests (no test framework / NuGet).</summary>
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

            try { Parser.ParseHeader(new byte[10]); Check(false, "truncated header should throw"); }
            catch (BinlogException e) { Check(e.Code == "truncated", "truncated code"); }

            try { Parser.ParseBuffer(new byte[4]); Check(false, "bad magic should throw"); }
            catch (BinlogException e) { Check(e.Code == "invalid", "invalid code"); }

            byte[] data = File.ReadAllBytes("fixtures/demo.bin");
            string expected = File.ReadAllText("fixtures/expected.jsonl");
            Check(Parser.ParseBuffer(data) == expected, "golden fixture");

            if (failures > 0) { Console.Error.WriteLine(failures + " failures"); return 1; }
            Console.WriteLine("csharp unit tests ok");
            return 0;
        }
    }
}
