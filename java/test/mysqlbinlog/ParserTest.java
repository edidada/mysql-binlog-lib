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

    /* Build a minimal well-formed event (magic + one event + CRC32) and return
       the full byte[]. event_size is derived from the body so the frame is
       always consistent. crcOverride < 0 stores the correct CRC; any other
       value is stored verbatim (to exercise checksum failure). */
    private static byte[] buildEvent(int eventType, int crcOverride, byte[] body) {
        int bodyLen = body.length;
        int es = Parser.HEADER_SIZE + bodyLen + Parser.CRC_SIZE;
        byte[] buf = new byte[Parser.MAGIC_SIZE + es];
        System.arraycopy(Parser.MAGIC, 0, buf, 0, Parser.MAGIC_SIZE);
        int frame = Parser.MAGIC_SIZE;
        putLe(buf, frame + 0, 1, 4);                       /* timestamp */
        buf[frame + 4] = (byte) eventType;
        putLe(buf, frame + 5, 1, 4);                       /* server_id */
        putLe(buf, frame + 9, es, 4);                      /* event_size */
        putLe(buf, frame + 13, es + Parser.MAGIC_SIZE, 4); /* next_position */
        putLe(buf, frame + 17, 0, 2);                      /* flags */
        System.arraycopy(body, 0, buf, frame + Parser.HEADER_SIZE, bodyLen);
        long crc = (crcOverride < 0)
                ? Parser.crc32(buf, frame, Parser.HEADER_SIZE + bodyLen)
                : (crcOverride & 0xFFFFFFFFL);
        putLe(buf, frame + Parser.HEADER_SIZE + bodyLen, crc, 4);
        return buf;
    }

    /* Assert that parsing throws BinlogError with the expected code. */
    private static void expectError(String expected, byte[] data, String msg) {
        try {
            Parser.parseBuffer(data);
            check(false, msg + " (no exception thrown)");
        } catch (Parser.BinlogError e) {
            check(expected.equals(e.code), msg + " (expected " + expected
                    + ", got " + e.code + ")");
        }
    }

    public static void main(String[] args) throws Exception {
        /* CRC-32 / IEEE standard vector. */
        check(Parser.crc32("123456789".getBytes(StandardCharsets.UTF_8), 0, 9)
                      == 0xCBF43926L,
              "crc32 vector");

        /* 19-byte little-endian header, decoded field by field. */
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

        /* Truncated / null header must not crash, just report an error. */
        try {
            Parser.parseHeader(new byte[10]);
            check(false, "truncated header should throw");
        } catch (Parser.BinlogError e) {
            check(e.code.equals("truncated"), "truncated code");
        }
        try {
            Parser.parseHeader(null);
            check(false, "null header should throw");
        } catch (Parser.BinlogError e) {
            check(e.code.equals("truncated"), "null header code");
        }

        /* Bad magic / null / too-short buffer are all rejected as invalid. */
        expectError("invalid", new byte[4], "bad magic should throw");
        expectError("invalid", null, "null buffer should throw");
        expectError("invalid", new byte[3], "short buffer should throw");

        /* A lone magic (no events) is a valid empty binlog -> no output. */
        check(Parser.parseBuffer(Parser.MAGIC).isEmpty(),
              "lone magic yields empty output");

        /* Truncated trailing header must be reported, not silently ignored. */
        expectError("truncated",
                    new byte[] { (byte) 0xFE, 0x62, 0x69, 0x6E, 1, 2, 3, 4 },
                    "truncated trailing header");

        /* event_size smaller than header+CRC is rejected before any read. */
        {
            byte[] ev = new byte[27];
            System.arraycopy(Parser.MAGIC, 0, ev, 0, 4);
            putLe(ev, 4, 1, 4);
            ev[8] = 99;
            putLe(ev, 9, 1, 4);
            putLe(ev, 13, 20, 4);      /* 20 < 19 + 4 */
            expectError("truncated", ev, "undersized event_size");
        }

        /* A valid UNKNOWN event is safely skipped and emitted as one JSON line. */
        {
            byte[] ev = buildEvent(99, -1, "abc".getBytes(StandardCharsets.UTF_8));
            check(ev.length == 4 + 26, "buildEvent size (magic + 19 + 3 + 4)");
            String line = Parser.parseBuffer(ev);
            check(line.equals(
                    "{\"type\":\"UNKNOWN\",\"timestamp\":1,"
                    + "\"type_id\":99,\"event_size\":26}\n"),
                  "valid UNKNOWN event output");
        }

        /* CRC mismatch is detected (CRC stored verbatim as 0, otherwise OK). */
        {
            byte[] ev = buildEvent(99, 0, "abc".getBytes(StandardCharsets.UTF_8));
            expectError("checksum", ev, "crc mismatch");
        }

        /* A corrupt event_size that claims more bytes than available. */
        {
            byte[] ev = buildEvent(99, -1, "abc".getBytes(StandardCharsets.UTF_8));
            putLe(ev, 4 + 9, 1000, 4);    /* event_size = 1000, buffer is 30 */
            expectError("truncated", ev, "oversized event_size");
        }

        /* An event_size above MAX_EVENT_SIZE is likewise rejected. */
        {
            byte[] ev = buildEvent(99, -1, "abc".getBytes(StandardCharsets.UTF_8));
            putLe(ev, 4 + 9, 0xFFFFFFFFL, 4);
            expectError("truncated", ev, "event_size beyond cap");
        }

        /* Golden fixture: byte-for-byte canonical JSONL. */
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
