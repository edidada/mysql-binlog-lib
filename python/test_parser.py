"""Unit + golden tests for the Python implementation (stdlib unittest)."""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from mysqlbinlog import ParseError, crc32, parse_buffer, parse_header  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def put_le(p, off, v, n):
    for i in range(n):
        p[off + i] = (v >> (8 * i)) & 0xFF


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

    def test_truncated_header(self):
        with self.assertRaises(ParseError):
            parse_header(bytes(10))

    def test_bad_magic(self):
        with self.assertRaises(ParseError) as cm:
            parse_buffer(bytes(4))
        self.assertEqual(cm.exception.code, "invalid")

    def test_golden(self):
        with open(os.path.join(ROOT, "fixtures", "demo.bin"), "rb") as f:
            data = f.read()
        with open(os.path.join(ROOT, "fixtures", "expected.jsonl"), "rb") as f:
            expected = f.read()
        self.assertEqual(parse_buffer(data).encode("utf-8"), expected)


if __name__ == "__main__":
    unittest.main(verbosity=2)
