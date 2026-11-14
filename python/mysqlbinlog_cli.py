#!/usr/bin/env python3
"""CLI for the Python implementation: mysqlbinlog-py."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from mysqlbinlog import ParseError, parse_buffer  # noqa: E402


def usage():
    sys.stderr.write("Usage: mysqlbinlog-py --file <path> [--format jsonl]\n")


def main(argv):
    path = None
    fmt = "jsonl"
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--help":
            usage()
            return 0
        elif a == "--file" and i + 1 < len(argv):
            path = argv[i + 1]
            i += 1
        elif a == "--format" and i + 1 < len(argv):
            fmt = argv[i + 1]
            i += 1
        else:
            sys.stderr.write("unknown argument: %s\n" % a)
            usage()
            return 2
        i += 1
    if not path:
        usage()
        return 2
    if fmt != "jsonl":
        sys.stderr.write("only --format jsonl is supported\n")
        return 2
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        sys.stderr.write("cannot open file: %s: %s\n" % (path, e))
        return 2
    try:
        out = parse_buffer(data)
    except ParseError as e:
        sys.stderr.write("parse failed: %s\n" % e.code)
        return 1
    sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
