package binlog

import (
	"bytes"
	"os"
	"testing"
)

func putLe(p []byte, v uint64, n int) {
	for i := 0; i < n; i++ {
		p[i] = byte(v >> (8 * i))
	}
}

func TestCRC32(t *testing.T) {
	if CRC32([]byte("123456789")) != 0xCBF43926 {
		t.Fatal("CRC-32 standard vector mismatch")
	}
}

func TestHeader(t *testing.T) {
	h := make([]byte, 19)
	putLe(h, 1700000000, 4)
	h[4] = 15
	putLe(h[5:9], 1, 4)
	putLe(h[9:13], 119, 4)
	putLe(h[13:17], 123, 4)
	putLe(h[17:19], 0, 2)
	out, err := ParseHeader(h)
	if err != nil {
		t.Fatal(err)
	}
	if out.Timestamp != 1700000000 || out.EventType != 15 || out.ServerID != 1 ||
		out.EventSize != 119 || out.NextPosition != 123 || out.Flags != 0 {
		t.Fatalf("bad header: %+v", out)
	}
}

func TestTruncatedHeader(t *testing.T) {
	if _, err := ParseHeader(make([]byte, 10)); err != ErrTruncated {
		t.Fatalf("want ErrTruncated, got %v", err)
	}
}

func TestBadMagic(t *testing.T) {
	var buf bytes.Buffer
	if err := ParseBuffer([]byte{0, 0, 0, 0}, &buf); err != ErrInvalid {
		t.Fatalf("want ErrInvalid, got %v", err)
	}
}

func TestGolden(t *testing.T) {
	data, err := os.ReadFile("../../fixtures/demo.bin")
	if err != nil {
		t.Fatal(err)
	}
	expected, err := os.ReadFile("../../fixtures/expected.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	if err := ParseBuffer(data, &buf); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(buf.Bytes(), expected) {
		t.Fatalf("golden mismatch\ngot:\n%s\nwant:\n%s", buf.String(), string(expected))
	}
}
