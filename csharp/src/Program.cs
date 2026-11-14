using System;
using System.IO;

namespace MysqlBinlog
{
    /// <summary>CLI: mysqlbinlog-cs --file &lt;path&gt; [--format jsonl]</summary>
    public static class Program
    {
        private static void Usage()
        {
            Console.Error.WriteLine("Usage: mysqlbinlog-cs --file <path> [--format jsonl]");
        }

        public static int Main(string[] args)
        {
            string file = null;
            string format = "jsonl";
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == "--help") { Usage(); return 0; }
                else if (args[i] == "--file" && i + 1 < args.Length) file = args[++i];
                else if (args[i] == "--format" && i + 1 < args.Length) format = args[++i];
                else { Console.Error.WriteLine("unknown argument: " + args[i]); Usage(); return 2; }
            }
            if (file == null) { Usage(); return 2; }
            if (format != "jsonl") { Console.Error.WriteLine("only --format jsonl is supported"); return 2; }
            byte[] data;
            try { data = File.ReadAllBytes(file); }
            catch (Exception e) { Console.Error.WriteLine("cannot open file: " + file + ": " + e.Message); return 2; }
            try
            {
                Console.Out.Write(Parser.ParseBuffer(data));
                Console.Out.Flush();
            }
            catch (BinlogException e)
            {
                Console.Error.WriteLine("parse failed: " + e.Code);
                return 1;
            }
            return 0;
        }
    }
}
