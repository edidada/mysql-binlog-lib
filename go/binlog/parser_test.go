package binlog

import (
	"bytes"
	"encoding/binary"
	"os"
	"testing"
)

func putLe(p []byte, v uint64, n int) {
	for i := 0; i < n; i++ {
		p[i] = byte(v >> (8 * i))
	}
}

// buildEvent frames one event: magic + header + body + CRC32.
func buildEvent(eventType byte, crcOverride *uint32, body []byte) []byte {
	es := 19 + len(body) + 4
	buf := make([]byte, 0, 4+es)
	buf = append(buf, 0xFE, 0x62, 0x69, 0x6E)
	header := make([]byte, 19)
	putLe(header[0:4], 1, 4)
	header[4] = eventType
	putLe(header[5:9], 1, 4)
	putLe(header[9:13], uint64(es), 4)
	putLe(header[13:17], uint64(es+4), 4)
	putLe(header[17:19], 0, 2)
	frame := append(append([]byte{}, header...), body...)
	var c uint32
	if crcOverride == nil {
		c = CRC32(frame)
	} else {
		c = *crcOverride
	}
	buf = append(buf, frame...)
	cb := make([]byte, 4)
	binary.LittleEndian.PutUint32(cb, c)
	return append(buf, cb...)
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
	if _, err := ParseHeader(nil); err != ErrTruncated {
		t.Fatalf("want ErrTruncated for nil, got %v", err)
	}
}

func TestBadMagic(t *testing.T) {
	var buf bytes.Buffer
	if err := ParseBuffer([]byte{0, 0, 0, 0}, &buf); err != ErrInvalid {
		t.Fatalf("want ErrInvalid, got %v", err)
	}
}

func TestEmptyBuffer(t *testing.T) {
	var buf bytes.Buffer
	if err := ParseBuffer(nil, &buf); err != ErrInvalid {
		t.Fatalf("want ErrInvalid, got %v", err)
	}
}

func TestValidUnknownEvent(t *testing.T) {
	var buf bytes.Buffer
	if err := ParseBuffer(buildEvent(99, nil, []byte{1, 2, 3}), &buf); err != nil {
		t.Fatal(err)
	}
	want := "{\"type\":\"UNKNOWN\",\"timestamp\":1,\"type_id\":99,\"event_size\":26}\n"
	if buf.String() != want {
		t.Fatalf("got %q, want %q", buf.String(), want)
	}
}

func TestCRCMismatch(t *testing.T) {
	zero := uint32(0)
	var buf bytes.Buffer
	if err := ParseBuffer(buildEvent(99, &zero, nil), &buf); err != ErrChecksum {
		t.Fatalf("want ErrChecksum, got %v", err)
	}
}

func TestTrailingPartialHeader(t *testing.T) {
	raw := append(buildEvent(99, nil, nil), 1, 2, 3)
	var buf bytes.Buffer
	if err := ParseBuffer(raw, &buf); err != ErrTruncated {
		t.Fatalf("want ErrTruncated, got %v", err)
	}
}

func TestEventSizeTooSmall(t *testing.T) {
	raw := buildEvent(99, nil, nil)
	putLe(raw[4+9:4+13], 10, 4)
	binary.LittleEndian.PutUint32(raw[len(raw)-4:], CRC32(raw[4:len(raw)-4]))
	var buf bytes.Buffer
	if err := ParseBuffer(raw, &buf); err != ErrTruncated {
		t.Fatalf("want ErrTruncated, got %v", err)
	}
}

func TestOversizedEventSize(t *testing.T) {
	raw := buildEvent(99, nil, nil)
	putLe(raw[4+9:4+13], 0xFFFFFFFF, 4)
	binary.LittleEndian.PutUint32(raw[len(raw)-4:], CRC32(raw[4:len(raw)-4]))
	var buf bytes.Buffer
	if err := ParseBuffer(raw, &buf); err != ErrTruncated {
		t.Fatalf("want ErrTruncated, got %v", err)
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
