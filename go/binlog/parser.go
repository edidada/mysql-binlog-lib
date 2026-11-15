// Package binlog implements the Phase 1 offline MySQL binlog parser for the
// controlled subset described in docs/design.md. It emits canonical JSONL
// shared by all ten language implementations.
//
// Layered structure (mirrors c/src/mysqlbinlog.c):
//
//   [1] ByteReader     bounds-checked little-endian primitives
//   [2] CRC-32         IEEE / zlib checksum
//   [3] Serializer     canonical JSONL builder (fixed key order, no spaces)
//   [4] SchemaRegistry table_id -> TableSchema
//   [5] RowDecoder     decode RowsEventV2 rows using a registered schema
//   [6] EventParser    frame/verify/dispatch events -> one JSONL line each
//   [7] Public API     ParseHeader / CRC32 / ParseBuffer
//
// The public API and the canonical JSONL are a cross-language contract shared
// by the other nine implementations and fixtures/expected.jsonl.
package binlog

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"strings"
)

// ==================================================================
// [0] Protocol constants (docs/design.md sections 2-3).
// ==================================================================
const (
	headerSize = 19
	crcSize    = 4
	magicSize  = 4

	maxCols       = 64
	maxTables     = 64
	maxEventSize  = 256 * 1024 * 1024 // defence against corrupt event sizes
	lineCap       = 16384             // max single JSONL line
	strCap        = 2048              // max query / next_file string
	valueCap      = 512               // max VARCHAR value
	nameCap       = 128               // max db / table name
	serverVersion = 50                // FDE server_version field length

	typeLong     = 3
	typeLonglong = 8
	typeVarchar  = 15

	evQuery         = 2
	evRotate        = 4
	evFormatDesc    = 15
	evXid           = 16
	evTableMap      = 19
	evRowsQuery     = 29
	evWriteRowsV2   = 30
	evUpdateRowsV2  = 31
	evDeleteRowsV2  = 32
	evGtid          = 33
)

var magic = [magicSize]byte{0xFE, 0x62, 0x69, 0x6E}

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

// ==================================================================
// [1] ByteReader: every read is bounds-checked; err latches.
// ==================================================================
type reader struct {
	data []byte
	len  int
	pos  int
	err  error
}

func newReader(data []byte) *reader {
	return &reader{data: data, len: len(data)}
}

func (r *reader) rem() int {
	if r.pos > r.len {
		return 0
	}
	return r.len - r.pos
}

// can is the overflow-safe "pos + n <= len" test.
func (r *reader) can(n int) bool {
	return r.err == nil && n >= 0 && n <= r.len && r.pos <= r.len-n
}

func (r *reader) fail(err error) {
	if r.err == nil {
		r.err = err
	}
}

func (r *reader) le(n int) uint64 {
	if n > 8 || !r.can(n) {
		r.fail(ErrTruncated)
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
	if !r.can(n) {
		r.fail(ErrTruncated)
		return nil
	}
	b := r.data[r.pos : r.pos+n]
	r.pos += n
	return b
}

// strn reads exactly n bytes as a bounded NUL-terminated string. The reader
// always advances by n (alignment preserved) even if the string is truncated.
func (r *reader) strn(n, cap int) string {
	if cap == 0 {
		return ""
	}
	if !r.can(n) {
		r.fail(ErrTruncated)
		return ""
	}
	m := n
	if m > cap-1 {
		m = cap - 1
	}
	s := string(r.data[r.pos : r.pos+m])
	r.pos += n
	return s
}

func (r *reader) skip(n int) {
	if !r.can(n) {
		r.fail(ErrTruncated)
		return
	}
	r.pos += n
}

// lenenc reads a MySQL length-encoded integer. 0xFB (NULL) and 0xFF
// (reserved) are not valid lengths where a length is required.
func (r *reader) lenenc() uint64 {
	b := byte(r.le(1))
	switch {
	case b < 0xFB:
		return uint64(b)
	case b == 0xFC:
		return r.le(2)
	case b == 0xFD:
		return r.le(3)
	case b == 0xFE:
		return r.le(8)
	default:
		r.fail(ErrUnsupported)
		return 0
	}
}

func (r *reader) position() int { return r.pos }
func (r *reader) setPos(n int)  { r.pos = n }

// ==================================================================
// [2] CRC-32 (IEEE 802.3 / zlib).
// Vector: CRC32([]byte("123456789")) == 0xCBF43926.
// ==================================================================
func CRC32(data []byte) uint32 {
	c := uint32(0xFFFFFFFF)
	for _, b := range data {
		c ^= uint32(b)
		for k := 0; k < 8; k++ {
			mask := uint32(0) - (c & 1)
			c = (c >> 1) ^ (0xEDB88320 & mask)
		}
	}
	return ^c
}

// ==================================================================
// [3] Serializer: bounded canonical JSONL builder.
// ==================================================================
type serializer struct {
	parts    []string
	length   int
	cap      int
	overflow bool
}

func newSerializer() *serializer { return &serializer{cap: lineCap} }

func (b *serializer) append(s string) {
	if b.overflow {
		return
	}
	if b.length+len(s) > b.cap {
		b.overflow = true
		return
	}
	b.parts = append(b.parts, s)
	b.length += len(s)
}

func (b *serializer) putc(c byte) { b.append(string(c)) }
func (b *serializer) puts(s string) { b.append(s) }
func (b *serializer) uint(v interface{}) { b.append(fmt.Sprint(v)) }

// jsonStr does minimal JSON escaping: quotes, backslash, control characters.
func (b *serializer) jsonStr(s string) {
	b.putc('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			b.puts(`\"`)
		case '\\':
			b.puts(`\\`)
		case '\n':
			b.puts(`\n`)
		case '\r':
			b.puts(`\r`)
		case '\t':
			b.puts(`\t`)
		default:
			if c < 0x20 {
				b.append(fmt.Sprintf(`\u%04x`, c))
			} else {
				b.putc(c)
			}
		}
	}
	b.putc('"')
}

func (b *serializer) line() string { return strings.Join(b.parts, "") }

func bit(v uint64, i int) bool { return v&(uint64(1)<<uint(i)) != 0 }

// ==================================================================
// [4] SchemaRegistry: table_id -> TableSchema, per-file lifetime.
// ==================================================================
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
	if len(g.v) < maxTables {
		g.v = append(g.v, s)
	}
}

func (g *registry) get(id uint64) *schema {
	for i := range g.v {
		if g.v[i].tableID == id {
			return &g.v[i]
		}
	}
	return nil
}

// ==================================================================
// [5] RowDecoder: decode a row sequence against a TableSchema.
// ==================================================================
func decodeValue(r *reader, s *schema, col int, isNull bool, b *serializer) error {
	if isNull {
		b.puts("null")
		return r.err
	}
	switch s.columnTypes[col] {
	case typeLonglong:
		b.uint(int64(r.le(8)))
	case typeLong:
		b.uint(int32(uint32(r.le(4))))
	case typeVarchar:
		lb := s.varcharLenBytes[col]
		if lb != 1 && lb != 2 {
			return ErrUnsupported
		}
		slen := int(r.le(lb))
		if slen > valueCap-1 {
			return ErrUnsupported
		}
		b.jsonStr(r.strn(slen, valueCap))
	default:
		return ErrUnsupported
	}
	return r.err
}

func decodeRows(r *reader, s *schema, present uint64, b *serializer) error {
	nbSize := (s.nullableCount + 7) / 8
	if nbSize > 8 {
		return ErrUnsupported
	}
	b.puts(`,"rows":[`)
	rowno := 0
	for r.rem() > 0 && r.err == nil {
		nullbm := r.le(nbSize)
		if r.err != nil {
			return r.err
		}
		if rowno > 0 {
			b.putc(',')
		}
		b.putc('[')
		first := true
		for i := 0; i < s.columnCount; i++ {
			if !bit(present, i) {
				continue
			}
			if !first {
				b.putc(',')
			}
			first = false
			if err := decodeValue(r, s, i, bit(nullbm, i), b); err != nil {
				return err
			}
		}
		b.putc(']')
		rowno++
	}
	b.puts(`]}`)
	return r.err
}

// ==================================================================
// [6] EventParser: header, framing, per-event dispatch.
// ==================================================================
func ParseHeader(data []byte) (EventHeader, error) {
	if len(data) < headerSize {
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

func rowsName(t uint8) string {
	switch t {
	case evWriteRowsV2:
		return "WRITE_ROWS_EVENT_V2"
	case evUpdateRowsV2:
		return "UPDATE_ROWS_EVENT_V2"
	case evDeleteRowsV2:
		return "DELETE_ROWS_EVENT_V2"
	}
	return "ROWS_EVENT_V2"
}

func parseFDE(r *reader, h *EventHeader, bodyLen int, b *serializer) error {
	if r.rem() < 2+serverVersion+1 {
		return ErrTruncated
	}
	bv := uint16(r.le(2))
	tmp := r.raw(serverVersion)
	alg := r.data[r.len-1]
	var sv strings.Builder
	for _, c := range tmp {
		if c == 0 {
			break
		}
		sv.WriteByte(c)
	}
	b.puts(`{"type":"FORMAT_DESCRIPTION_EVENT","timestamp":`)
	b.uint(h.Timestamp)
	b.puts(`,"binlog_version":`)
	b.uint(bv)
	b.puts(`,"server_version":`)
	b.jsonStr(sv.String())
	b.puts(`,"checksum_alg":`)
	b.uint(alg)
	b.putc('}')
	return r.err
}

func parseGTID(r *reader, h *EventHeader, b *serializer) error {
	r.le(1) // flags
	sid := r.raw(16)
	gno := r.le(8)
	if r.err != nil {
		return r.err
	}
	sh := fmt.Sprintf("%x", sid)
	b.puts(`{"type":"GTID_LOG_EVENT","timestamp":`)
	b.uint(h.Timestamp)
	b.puts(`,"gno":`)
	b.uint(gno)
	b.puts(`,"sid":`)
	b.jsonStr(sh)
	b.putc('}')
	return nil
}

func parseQuery(r *reader, h *EventHeader, b *serializer) error {
	r.le(4) // thread_id
	r.le(4) // exec_time
	dbl := int(r.le(1))
	r.le(2) // error_code
	svl := int(r.le(2))
	r.skip(svl) // status_vars
	db := r.strn(dbl, nameCap)
	r.le(1) // trailing NUL after db
	query := r.strn(r.rem(), strCap)
	if r.err != nil {
		return r.err
	}
	b.puts(`{"type":"QUERY_EVENT","timestamp":`)
	b.uint(h.Timestamp)
	b.puts(`,"db":`)
	b.jsonStr(db)
	b.puts(`,"query":`)
	b.jsonStr(query)
	b.putc('}')
	return nil
}

func parseRowsQuery(r *reader, h *EventHeader, b *serializer) error {
	ln := r.lenenc()
	q := r.strn(int(ln), strCap)
	if r.err != nil {
		return r.err
	}
	b.puts(`{"type":"ROWS_QUERY_LOG_EVENT","timestamp":`)
	b.uint(h.Timestamp)
	b.puts(`,"query":`)
	b.jsonStr(q)
	b.putc('}')
	return nil
}

func parseTableMap(r *reader, h *EventHeader, reg *registry, b *serializer) error {
	var s schema
	s.tableID = r.le(6)
	r.le(2) // flags
	dbl := int(r.le(1))
	s.db = r.strn(dbl, nameCap)
	r.le(1) // NUL
	tl := int(r.le(1))
	s.table = r.strn(tl, nameCap)
	r.le(1) // NUL
	cc := int(r.lenenc())
	if r.err != nil {
		return r.err
	}
	if cc == 0 || cc > maxCols {
		return ErrUnsupported
	}
	s.columnCount = cc
	for i := 0; i < cc; i++ {
		s.columnTypes = append(s.columnTypes, byte(r.le(1)))
	}
	mdLen := int(r.lenenc())
	mdStart := r.position()
	if r.err != nil || mdLen > r.len || mdStart > r.len-mdLen {
		return ErrTruncated
	}
	s.varcharLenBytes = make([]int, cc)
	for i, ct := range s.columnTypes {
		if ct == typeVarchar {
			if r.position()+2 > mdStart+mdLen {
				return ErrTruncated
			}
			mx := uint16(r.le(2))
			if mx > 255 {
				s.varcharLenBytes[i] = 2
			} else {
				s.varcharLenBytes[i] = 1
			}
		}
	}
	r.setPos(mdStart + mdLen) // skip any extra metadata

	nb := (cc + 7) / 8
	if nb > 8 {
		return ErrUnsupported
	}
	nullbm := r.le(nb)
	for i := 0; i < cc; i++ {
		if bit(nullbm, i) {
			s.nullableCount++
		}
	}
	if r.err != nil {
		return r.err
	}
	reg.put(s)

	b.puts(`{"type":"TABLE_MAP_EVENT","timestamp":`)
	b.uint(h.Timestamp)
	b.puts(`,"table_id":`)
	b.uint(s.tableID)
	b.puts(`,"db":`)
	b.jsonStr(s.db)
	b.puts(`,"table":`)
	b.jsonStr(s.table)
	b.puts(`,"column_count":`)
	b.uint(cc)
	b.puts(`,"column_types":[`)
	for i, ct := range s.columnTypes {
		if i > 0 {
			b.putc(',')
		}
		b.uint(ct)
	}
	b.puts(`]}`)
	return nil
}

func parseRowsV2(r *reader, h *EventHeader, reg *registry, b *serializer) error {
	tid := r.le(6)
	r.le(2) // flags
	extraLen := int(r.le(2))
	if extraLen < 2 {
		return ErrUnsupported
	}
	r.skip(extraLen - 2)
	cc := int(r.lenenc())
	if r.err != nil {
		return r.err
	}
	if cc == 0 || cc > maxCols {
		return ErrUnsupported
	}
	bmSize := (cc + 7) / 8
	if bmSize > 8 {
		return ErrUnsupported
	}
	present := r.le(bmSize)
	if h.EventType == evUpdateRowsV2 {
		r.le(bmSize) // before/after bitmap (equal in this subset)
	}
	if r.err != nil {
		return r.err
	}
	s := reg.get(tid)
	if s == nil {
		return ErrNoSchema
	}

	b.puts(`{"type":"`)
	b.puts(rowsName(h.EventType))
	b.puts(`","timestamp":`)
	b.uint(h.Timestamp)
	b.puts(`,"table_id":`)
	b.uint(tid)
	b.puts(`,"db":`)
	b.jsonStr(s.db)
	b.puts(`,"table":`)
	b.jsonStr(s.table)
	return decodeRows(r, s, present, b)
}

func parseXID(r *reader, h *EventHeader, b *serializer) error {
	xid := r.le(8)
	if r.err != nil {
		return r.err
	}
	b.puts(`{"type":"XID_EVENT","timestamp":`)
	b.uint(h.Timestamp)
	b.puts(`,"xid":`)
	b.uint(xid)
	b.putc('}')
	return nil
}

func parseRotate(r *reader, h *EventHeader, b *serializer) error {
	position := r.le(8)
	nf := r.strn(r.rem(), strCap)
	if r.err != nil {
		return r.err
	}
	b.puts(`{"type":"ROTATE_EVENT","timestamp":`)
	b.uint(h.Timestamp)
	b.puts(`,"position":`)
	b.uint(position)
	b.puts(`,"next_file":`)
	b.jsonStr(nf)
	b.putc('}')
	return nil
}

func parseUnknown(h *EventHeader, b *serializer) {
	b.puts(`{"type":"UNKNOWN","timestamp":`)
	b.uint(h.Timestamp)
	b.puts(`,"type_id":`)
	b.uint(h.EventType)
	b.puts(`,"event_size":`)
	b.uint(h.EventSize)
	b.putc('}')
}

// dispatchEvent sends one verified event body to its named handler.
func dispatchEvent(h *EventHeader, body []byte, reg *registry, b *serializer) error {
	r := newReader(body)
	switch h.EventType {
	case evFormatDesc:
		return parseFDE(r, h, len(body), b)
	case evGtid:
		return parseGTID(r, h, b)
	case evQuery:
		return parseQuery(r, h, b)
	case evRowsQuery:
		return parseRowsQuery(r, h, b)
	case evTableMap:
		return parseTableMap(r, h, reg, b)
	case evWriteRowsV2, evUpdateRowsV2, evDeleteRowsV2:
		return parseRowsV2(r, h, reg, b)
	case evXid:
		return parseXID(r, h, b)
	case evRotate:
		return parseRotate(r, h, b)
	default: // UNKNOWN -> safe skip, stable one-line record
		parseUnknown(h, b)
		return nil
	}
}

// ==================================================================
// [7] Public API: whole-buffer parser.
// ==================================================================
// ParseBuffer parses a whole binlog buffer and writes canonical JSONL lines
// (one per event) to out.
func ParseBuffer(data []byte, out io.Writer) error {
	if len(data) < magicSize {
		return ErrInvalid
	}
	if data[0] != magic[0] || data[1] != magic[1] ||
		data[2] != magic[2] || data[3] != magic[3] {
		return ErrInvalid
	}

	var reg registry
	pos := magicSize
	for pos < len(data) {
		if len(data)-pos < headerSize {
			return ErrTruncated
		}
		h, err := ParseHeader(data[pos : pos+headerSize])
		if err != nil {
			return err
		}
		es := int(h.EventSize)
		if es < headerSize+crcSize || es > maxEventSize || es > len(data)-pos {
			return ErrTruncated
		}
		full := data[pos : pos+es]
		// Every event in the controlled subset carries CRC32 (FDE declares
		// checksum_alg=1), so it is verified unconditionally here.
		stored := binary.LittleEndian.Uint32(full[es-crcSize:])
		calc := CRC32(full[:es-crcSize])
		if stored != calc {
			return ErrChecksum
		}

		body := full[headerSize : es-crcSize]
		b := newSerializer()
		if err := dispatchEvent(&h, body, &reg, b); err != nil {
			return err
		}
		if b.overflow {
			return ErrInvalid
		}
		fmt.Fprintln(out, b.line())
		pos += es
	}
	return nil
}
