package mysqlbinlog;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;

/** Self-contained unit + golden tests (no JUnit, keeps the build dependency-free). */
public final class ParserTest {

    private ParserTest() {}

    private static int failures = 0;

    private static void check(boolean cond, String msg) {
        if (!cond) {
            System.err.println("FAIL: " + msg);
            failures++;
        }
    }

    private static void putLe(byte[] p, int off, long v, int n) {
        for (int i = 0; i < n; i++) p[off + i] = (byte) (v >>> (8 * i));
    }

    public static void main(String[] args) throws Exception {
        check(Parser.crc32("123456789".getBytes(StandardCharsets.UTF_8), 0, 9) == 0xCBF43926L,
              "crc32 vector");

        byte[] h = new byte[19];
        putLe(h, 0, 1700000000L, 4);
        h[4] = 15;
        putLe(h, 5, 1, 4);
        putLe(h, 9, 119, 4);
        putLe(h, 13, 123, 4);
        putLe(h, 17, 0, 2);
        Parser.Header hd = Parser.parseHeader(h);
        check(hd.timestamp == 1700000000L, "timestamp");
        check(hd.eventType == 15, "eventType");
        check(hd.serverId == 1, "serverId");
        check(hd.eventSize == 119, "eventSize");
        check(hd.nextPosition == 123, "nextPosition");
        check(hd.flags == 0, "flags");

        try {
            Parser.parseHeader(new byte[10]);
            check(false, "truncated header should throw");
        } catch (Parser.BinlogError e) {
            check(e.code.equals("truncated"), "truncated code");
        }

        try {
            Parser.parseBuffer(new byte[4]);
            check(false, "bad magic should throw");
        } catch (Parser.BinlogError e) {
            check(e.code.equals("invalid"), "invalid code");
        }

        byte[] data = Files.readAllBytes(Paths.get("fixtures/demo.bin"));
        String expected = new String(Files.readAllBytes(Paths.get("fixtures/expected.jsonl")),
                                     StandardCharsets.UTF_8);
        check(Parser.parseBuffer(data).equals(expected), "golden fixture");

        if (failures > 0) {
            System.err.println(failures + " failures");
            System.exit(1);
        }
        System.out.println("java unit tests ok");
    }
}
