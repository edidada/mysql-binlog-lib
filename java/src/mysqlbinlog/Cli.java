package mysqlbinlog;

import java.nio.file.Files;
import java.nio.file.Paths;

/** CLI: mysqlbinlog-java --file <path> [--format jsonl] */
public final class Cli {

    private Cli() {}

    private static void usage() {
        System.err.println("Usage: mysqlbinlog-java --file <path> [--format jsonl]");
    }

    public static void main(String[] args) {
        String file = null;
        String format = "jsonl";
        for (int i = 0; i < args.length; i++) {
            if (args[i].equals("--help")) {
                usage();
                return;
            } else if (args[i].equals("--file") && i + 1 < args.length) {
                file = args[++i];
            } else if (args[i].equals("--format") && i + 1 < args.length) {
                format = args[++i];
            } else {
                System.err.println("unknown argument: " + args[i]);
                usage();
                System.exit(2);
            }
        }
        if (file == null) {
            usage();
            System.exit(2);
        }
        if (!format.equals("jsonl")) {
            System.err.println("only --format jsonl is supported");
            System.exit(2);
        }
        byte[] data;
        try {
            data = Files.readAllBytes(Paths.get(file));
        } catch (Exception e) {
            System.err.println("cannot open file: " + file + ": " + e);
            System.exit(2);
            return;
        }
        try {
            System.out.print(Parser.parseBuffer(data));
            System.out.flush();
        } catch (Parser.BinlogError e) {
            System.err.println("parse failed: " + e.code);
            System.exit(1);
        }
    }
}
