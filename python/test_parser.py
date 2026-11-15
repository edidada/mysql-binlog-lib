"""Unit + golden tests for the Python implementation (stdlib unittest).

Mirrors c/tests/test_parser.c: CRC vector, header fields, framing/CRC/truncation
error paths, and the cross-language golden JSONL.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from mysqlbinlog import ParseError, crc32, parse_buffer, parse_header  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def put_le(p, off, v, n):
    for i in range(n):
        p[off + i] = (v >> (8 * i)) & 0xFF


def build_event(event_type, crc_override=None, body=b""):
    """Build magic + one framed event (header + body + CRC32)."""
    es = 19 + len(body) + 4
    buf = bytearray(b"\xfe\x62\x69\x6e")
    frame = bytearray(19)
    put_le(frame, 0, 1, 4)
    frame[4] = event_type
    put_le(frame, 5, 1, 4)
    put_le(frame, 9, es, 4)
    put_le(frame, 13, es + 4, 4)
    put_le(frame, 17, 0, 2)
    buf += frame
    buf += body
    c = crc32(bytes(frame + body)) if crc_override is None else crc_override
    buf += bytes(4)
    put_le(buf, len(buf) - 4, c, 4)
    return bytes(buf)


class ParserTests(unittest.TestCase):
    def test_crc32(self):
        self.assertEqual(crc32(b"123456789"), 0xCBF43926)

    def test_header(self):
        h = bytearray(19)
        put_le(h, 0, 1700000000, 4)
        h[4] = 15
        put_le(h, 5, 1, 4)
        put_le(h, 9, 119, 4)
        put_le(h, 13, 123, 4)
        put_le(h, 17, 0, 2)
        out = parse_header(bytes(h))
        self.assertEqual(out["timestamp"], 1700000000)
        self.assertEqual(out["event_type"], 15)
        self.assertEqual(out["server_id"], 1)
        self.assertEqual(out["event_size"], 119)
        self.assertEqual(out["next_position"], 123)
        self.assertEqual(out["flags"], 0)

    def test_truncated_and_null_header(self):
        with self.assertRaises(ParseError):
            parse_header(bytes(10))
        with self.assertRaises(ParseError):
            parse_header(None)

    def test_bad_magic(self):
        with self.assertRaises(ParseError) as cm:
            parse_buffer(bytes(4))
        self.assertEqual(cm.exception.code, "invalid")

    def test_empty_buffer(self):
        with self.assertRaises(ParseError) as cm:
            parse_buffer(b"")
        self.assertEqual(cm.exception.code, "invalid")

    def test_valid_unknown_event(self):
        out = parse_buffer(build_event(99, body=b"\x01\x02\x03"))
        self.assertEqual(
            out,
            '{"type":"UNKNOWN","timestamp":1,"type_id":99,'
            '"event_size":26}\n',
        )

    def test_crc_mismatch(self):
        with self.assertRaises(ParseError) as cm:
            parse_buffer(build_event(99, crc_override=0))
        self.assertEqual(cm.exception.code, "checksum")

    def test_trailing_partial_header(self):
        buf = bytearray(build_event(99))
        buf += b"\x01\x02\x03"
        with self.assertRaises(ParseError) as cm:
            parse_buffer(bytes(buf))
        self.assertEqual(cm.exception.code, "truncated")

    def test_event_size_too_small(self):
        raw = bytearray(build_event(99))
        put_le(raw, 4 + 9, 10, 4)     # event_size field inside header
        # Recompute CRC over the (now modified) header+body so framing reaches
        # the size check rather than failing on checksum first.
        frame = raw[4:-4]
        put_le(raw, len(raw) - 4, crc32(bytes(frame)), 4)
        with self.assertRaises(ParseError) as cm:
            parse_buffer(bytes(raw))
        self.assertEqual(cm.exception.code, "truncated")

    def test_oversized_event_size(self):
        raw = bytearray(build_event(99))
        put_le(raw, 4 + 9, 0xFFFFFFFF, 4)
        frame = raw[4:-4]
        put_le(raw, len(raw) - 4, crc32(bytes(frame)), 4)
        with self.assertRaises(ParseError) as cm:
            parse_buffer(bytes(raw))
        self.assertEqual(cm.exception.code, "truncated")

    def test_golden(self):
        with open(os.path.join(ROOT, "fixtures", "demo.bin"), "rb") as f:
            data = f.read()
        with open(os.path.join(ROOT, "fixtures", "expected.jsonl"), "rb") as f:
            expected = f.read()
        self.assertEqual(parse_buffer(data).encode("utf-8"), expected)


if __name__ == "__main__":
    unittest.main(verbosity=2)
