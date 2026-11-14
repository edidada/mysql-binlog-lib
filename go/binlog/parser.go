// Package binlog implements the Phase 1 offline MySQL binlog parser for the
// controlled subset described in docs/design.md. It emits canonical JSONL
// shared by the C, C++, Rust and Go implementations.
package binlog

import (
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"strings"
)

var (
	ErrInvalid     = errors.New("invalid binlog")
	ErrTruncated   = errors.New("truncated event")
	ErrChecksum    = errors.New("crc32 mismatch")
	ErrNoSchema    = errors.New("no table map schema")
	ErrUnsupported = errors.New("unsupported column type")
)

// EventHeader is the 19-byte little-endian common event header.
type EventHeader struct {
	Timestamp    uint32
	EventType    uint8
	ServerID     uint32
	EventSize    uint32
	NextPosition uint32
	Flags        uint16
}

// ---- ByteReader ----------------------------------------------------------
type reader struct {
	data []byte
	pos  int
	err  error
}

func newReader(data []byte) *reader { return &reader{data: data} }

func (r *reader) rem() int {
	if r.pos >= len(r.data) {
		return 0
	}
	return len(r.data) - r.pos
}

func (r *reader) position() int  { return r.pos }
func (r *reader) setPos(n int)   { r.pos = n }

func (r *reader) lastByte() byte {
	if len(r.data) == 0 {
		return 0
	}
	return r.data[len(r.data)-1]
}

func (r *reader) le(n int) uint64 {
	if r.err != nil {
		return 0
	}
	if n < 0 || n > 8 || r.pos+n > len(r.data) {
		r.err = ErrTruncated
		return 0
	}
	var v uint64
	for i := 0; i < n; i++ {
		v |= uint64(r.data[r.pos+i]) << (8 * i)
	}
	r.pos += n
	return v
}

func (r *reader) raw(n int) []byte {
	if r.err != nil {
		return nil
	}
	if r.pos+n > len(r.data) {
		r.err = ErrTruncated
		return nil
	}
	b := r.data[r.pos : r.pos+n]
	r.pos += n
	return b
}

func (r *reader) strn(n int) string {
	b := r.raw(n)
	if b == nil {
		return ""
	}
	return string(b)
}

func (r *reader) skip(n int) {
	if r.err != nil {
		return
	}
	if r.pos+n > len(r.data) {
		r.err = ErrTruncated
		r.pos = len(r.data)
		return
	}
	r.pos += n
}

func (r *reader) lenenc() (uint64, bool) {
	b := byte(r.le(1))
	switch {
	case b < 0xFB:
		return uint64(b), false
	case b == 0xFB:
		return 0, true
	case b == 0xFC:
		return r.le(2), false
	case b == 0xFD:
		return r.le(3), false
	case b == 0xFE:
		return r.le(8), false
	default:
		return 0, false
	}
}

func (r *reader) lenencU() uint64 { v, _ := r.lenenc(); return v }

// ---- CRC-32 --------------------------------------------------------------
func CRC32(data []byte) uint32 { return crc32.ChecksumIEEE(data) }

// ---- Canonical JSON helpers ---------------------------------------------
func num(v interface{}) string { return fmt.Sprint(v) }

func jsonStr(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if c < 0x20 {
				fmt.Fprintf(&b, `\u%04x`, c)
			} else {
				b.WriteByte(c)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

func bit(v uint64, i int) bool { return v&(uint64(1)<<uint(i)) != 0 }

// ---- SchemaRegistry ------------------------------------------------------
type schema struct {
	tableID         uint64
	db, table       string
	columnCount     int
	columnTypes     []byte
	varcharLenBytes []int
	nullableCount   int
}

type registry struct{ v []schema }

func (g *registry) put(s schema) {
	for i := range g.v {
		if g.v[i].tableID == s.tableID {
			g.v[i] = s
			return
		}
	}
	g.v = append(g.v, s)
}

func (g *registry) get(id uint64) *schema {
	for i := range g.v {
		if g.v[i].tableID == id {
			return &g.v[i]
		}
	}
	return nil
}

func rowsName(t uint8) string {
	switch t {
	case 30:
		return "WRITE_ROWS_EVENT_V2"
	case 31:
		return "UPDATE_ROWS_EVENT_V2"
	case 32:
		return "DELETE_ROWS_EVENT_V2"
	}
	return "ROWS_EVENT_V2"
}

// ---- Public API ----------------------------------------------------------
func ParseHeader(data []byte) (EventHeader, error) {
	if len(data) < 19 {
		return EventHeader{}, ErrTruncated
	}
	r := newReader(data)
	var h EventHeader
	h.Timestamp = uint32(r.le(4))
	h.EventType = uint8(r.le(1))
	h.ServerID = uint32(r.le(4))
	h.EventSize = uint32(r.le(4))
	h.NextPosition = uint32(r.le(4))
	h.Flags = uint16(r.le(2))
	return h, r.err
}

func emit(h *EventHeader, body []byte, r *reader, reg *registry) (string, error) {
	var b strings.Builder
	switch h.EventType {
	case 15: // FORMAT_DESCRIPTION_EVENT
		bv := uint16(r.le(2))
		tmp := r.raw(50)
		alg := r.lastByte()
		var sv strings.Builder
		for _, c := range tmp {
			if c == 0 {
				break
			}
			sv.WriteByte(c)
		}
		b.WriteString(`{"type":"FORMAT_DESCRIPTION_EVENT","timestamp":`)
		b.WriteString(num(h.Timestamp))
		b.WriteString(`,"binlog_version":`)
		b.WriteString(num(bv))
		b.WriteString(`,"server_version":`)
		b.WriteString(jsonStr(sv.String()))
		b.WriteString(`,"checksum_alg":`)
		b.WriteString(num(alg))
		b.WriteByte('}')

	case 33: // GTID_LOG_EVENT
		r.le(1) // flags
		sid := r.raw(16)
		gno := r.le(8)
		sh := fmt.Sprintf("%x", sid)
		b.WriteString(`{"type":"GTID_LOG_EVENT","timestamp":`)
		b.WriteString(num(h.Timestamp))
		b.WriteString(`,"gno":`)
		b.WriteString(num(gno))
		b.WriteString(`,"sid":`)
		b.WriteString(jsonStr(sh))
		b.WriteByte('}')

	case 2: // QUERY_EVENT
		r.le(4) // thread_id
		r.le(4) // exec_time
		dbl := int(r.le(1))
		r.le(2) // error_code
		svl := int(r.le(2))
		r.skip(svl)
		db := r.strn(dbl)
		r.le(1) // trailing NUL
		query := r.strn(r.rem())
		b.WriteString(`{"type":"QUERY_EVENT","timestamp":`)
		b.WriteString(num(h.Timestamp))
		b.WriteString(`,"db":`)
		b.WriteString(jsonStr(db))
		b.WriteString(`,"query":`)
		b.WriteString(jsonStr(query))
		b.WriteByte('}')

	case 29: // ROWS_QUERY_LOG_EVENT
		ln := r.lenencU()
		q := r.strn(int(ln))
		b.WriteString(`{"type":"ROWS_QUERY_LOG_EVENT","timestamp":`)
		b.WriteString(num(h.Timestamp))
		b.WriteString(`,"query":`)
		b.WriteString(jsonStr(q))
		b.WriteByte('}')

	case 19: // TABLE_MAP_EVENT
		var s schema
		s.tableID = r.le(6)
		r.le(2) // flags
		dbl := int(r.le(1))
		s.db = r.strn(dbl)
		r.le(1) // NUL
		tl := int(r.le(1))
		s.table = r.strn(tl)
		r.le(1) // NUL
		cc := int(r.lenencU())
		s.columnCount = cc
		for i := 0; i < cc; i++ {
			s.columnTypes = append(s.columnTypes, byte(r.le(1)))
		}
		mdlen := int(r.lenencU())
		mdstart := r.position()
		for i := 0; i < cc; i++ {
			if s.columnTypes[i] == 15 {
				mx := uint16(r.le(2))
				if mx > 255 {
					s.varcharLenBytes = append(s.varcharLenBytes, 2)
				} else {
					s.varcharLenBytes = append(s.varcharLenBytes, 1)
				}
			} else {
				s.varcharLenBytes = append(s.varcharLenBytes, 0)
			}
		}
		r.setPos(mdstart + mdlen)
		nb := (cc + 7) / 8
		nullbm := r.le(nb)
		nullable := 0
		for i := 0; i < cc; i++ {
			if bit(nullbm, i) {
				nullable++
			}
		}
		s.nullableCount = nullable
		reg.put(s)

		b.WriteString(`{"type":"TABLE_MAP_EVENT","timestamp":`)
		b.WriteString(num(h.Timestamp))
		b.WriteString(`,"table_id":`)
		b.WriteString(num(s.tableID))
		b.WriteString(`,"db":`)
		b.WriteString(jsonStr(s.db))
		b.WriteString(`,"table":`)
		b.WriteString(jsonStr(s.table))
		b.WriteString(`,"column_count":`)
		b.WriteString(num(cc))
		b.WriteString(`,"column_types":[`)
		for i := 0; i < cc; i++ {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(num(s.columnTypes[i]))
		}
		b.WriteString(`]}`)

	case 30, 31, 32: // ROWS_EVENT_V2
		tid := r.le(6)
		r.le(2) // flags
		el := int(r.le(2))
		if el >= 2 {
			r.skip(el - 2)
		}
		cc := int(r.lenencU())
		bm := (cc + 7) / 8
		present1 := r.le(bm)
		if h.EventType == 31 {
			r.le(bm) // bitmap2, equal
		}
		se := reg.get(tid)
		if se == nil {
			return "", ErrNoSchema
		}
		nbs := (se.nullableCount + 7) / 8

		b.WriteString(`{"type":"`)
		b.WriteString(rowsName(h.EventType))
		b.WriteString(`","timestamp":`)
		b.WriteString(num(h.Timestamp))
		b.WriteString(`,"table_id":`)
		b.WriteString(num(tid))
		b.WriteString(`,"db":`)
		b.WriteString(jsonStr(se.db))
		b.WriteString(`,"table":`)
		b.WriteString(jsonStr(se.table))
		b.WriteString(`,"rows":[`)
		rowno := 0
		for r.rem() > 0 {
			nullbm := r.le(nbs)
			if r.err != nil {
				break
			}
			if rowno > 0 {
				b.WriteByte(',')
			}
			b.WriteByte('[')
			first := true
			for i := 0; i < se.columnCount; i++ {
				if !bit(present1, i) {
					continue
				}
				if !first {
					b.WriteByte(',')
				}
				first = false
				if bit(nullbm, i) {
					b.WriteString("null")
					continue
				}
				switch se.columnTypes[i] {
				case 8: // LONGLONG
					v := int64(r.le(8))
					b.WriteString(num(v))
				case 3: // LONG
					v := int32(uint32(r.le(4)))
					b.WriteString(num(v))
				case 15: // VARCHAR
					lb := se.varcharLenBytes[i]
					if lb == 0 {
						lb = 1
					}
					slen := int(r.le(lb))
					val := r.strn(slen)
					b.WriteString(jsonStr(val))
				default:
					return "", ErrUnsupported
				}
				if r.err != nil {
					break
				}
			}
			b.WriteByte(']')
			if r.err != nil {
				break
			}
			rowno++
		}
		b.WriteString(`]}`)

	case 16: // XID_EVENT
		xid := r.le(8)
		b.WriteString(`{"type":"XID_EVENT","timestamp":`)
		b.WriteString(num(h.Timestamp))
		b.WriteString(`,"xid":`)
		b.WriteString(num(xid))
		b.WriteByte('}')

	case 4: // ROTATE_EVENT
		position := r.le(8)
		nf := r.strn(r.rem())
		b.WriteString(`{"type":"ROTATE_EVENT","timestamp":`)
		b.WriteString(num(h.Timestamp))
		b.WriteString(`,"position":`)
		b.WriteString(num(position))
		b.WriteString(`,"next_file":`)
		b.WriteString(jsonStr(nf))
		b.WriteByte('}')

	default: // UNKNOWN -> safe skip
		b.WriteString(`{"type":"UNKNOWN","timestamp":`)
		b.WriteString(num(h.Timestamp))
		b.WriteString(`,"type_id":`)
		b.WriteString(num(h.EventType))
		b.WriteString(`,"event_size":`)
		b.WriteString(num(h.EventSize))
		b.WriteByte('}')
	}
	return b.String(), r.err
}

// ParseBuffer parses a whole binlog buffer and writes canonical JSONL lines
// (one per event) to out.
func ParseBuffer(data []byte, out io.Writer) error {
	if len(data) < 4 {
		return ErrInvalid
	}
	if !(data[0] == 0xFE && data[1] == 'b' && data[2] == 'i' && data[3] == 'n') {
		return ErrInvalid
	}
	var reg registry
	pos := 4 // skip magic
	for pos < len(data) {
		if pos+19 > len(data) {
			return ErrTruncated
		}
		h, err := ParseHeader(data[pos : pos+19])
		if err != nil {
			return err
		}
		es := int(h.EventSize)
		if es < 19+4 || pos+es > len(data) {
			return ErrTruncated
		}
		full := data[pos : pos+es]
		// Controlled subset: every event carries CRC32 (FDE declares alg=1).
		stored := binary.LittleEndian.Uint32(full[es-4:])
		calc := CRC32(full[:es-4])
		if stored != calc {
			return ErrChecksum
		}
		body := full[19 : es-4]
		r := newReader(body)
		line, err := emit(&h, body, r, &reg)
		if err != nil {
			return err
		}
		fmt.Fprintln(out, line)
		pos += es
	}
	return nil
}
