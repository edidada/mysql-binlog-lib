/*
 * mysqlbinlog.cpp - offline MySQL binlog parser (Phase 1 controlled subset).
 *
 * Layered structure (mirrors docs/design.md section 4 and c/src/mysqlbinlog.c):
 *
 *   [1] ByteReader     bounds-checked little-endian primitives
 *   [2] CRC-32         IEEE / zlib checksum
 *   [3] Serializer     canonical JSONL builder (fixed key order, no spaces)
 *   [4] SchemaRegistry table_id -> TableSchema
 *   [5] RowDecoder     decode RowsEventV2 rows using a registered schema
 *   [6] EventParser    frame/verify/dispatch events -> one JSONL line each
 *   [7] Public API     parse_header / crc32 / parse_buffer
 *
 * The public API in include/mysqlbinlog.hpp and the emitted JSONL are a
 * contract with the other language implementations (fixtures/expected.jsonl).
 * Do not change either without a cross-language update.
 */

#include "mysqlbinlog.hpp"

#include <cstdarg>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ostream>
#include <string>
#include <vector>

namespace mysqlbinlog {

// Protocol constants (docs/design.md sections 2 and 3).
namespace {
constexpr size_t kHeaderSize   = 19;
constexpr size_t kCrcSize      = 4;
constexpr size_t kMagicSize    = 4;
constexpr size_t kMaxCols      = 64;
constexpr size_t kMaxTables    = 64;
constexpr size_t kMaxEventSize = 256u * 1024u * 1024u; // defence against corrupt sizes
constexpr size_t kLineCap      = 16384;                 // max single JSONL line

// Bounded string buffers: every length coming off the wire is checked against
// one of these caps before being copied (no unbounded strcpy).
constexpr size_t kNameCap     = 128;  // db / table names
constexpr size_t kQueryCap    = 2048; // QUERY_EVENT / ROWS_QUERY query text
constexpr size_t kVarcharCap  = 512;  // decoded VARCHAR value
constexpr size_t kNextFileCap = 512;  // ROTATE_EVENT file name

// Column type ids used by the controlled subset.
constexpr uint8_t kTypeLong     = 3;
constexpr uint8_t kTypeLonglong = 8;
constexpr uint8_t kTypeVarchar  = 15;

// Event type ids (docs/design.md section 3).
constexpr uint8_t kEvQuery        = 2;
constexpr uint8_t kEvRotate       = 4;
constexpr uint8_t kEvFormatDesc   = 15;
constexpr uint8_t kEvXid          = 16;
constexpr uint8_t kEvTableMap     = 19;
constexpr uint8_t kEvRowsQuery    = 29;
constexpr uint8_t kEvWriteRowsV2  = 30;
constexpr uint8_t kEvUpdateRowsV2 = 31;
constexpr uint8_t kEvDeleteRowsV2 = 32;
constexpr uint8_t kEvGtid         = 33;

constexpr uint8_t kMagic[kMagicSize] = { 0xFE, 0x62, 0x69, 0x6E };
} // namespace

// === [1] ByteReader ===
// Every read is bounds-checked; the error flag latches once set.
namespace {
class ByteReader {
public:
    ByteReader(const uint8_t* p, size_t len)
        : p_(p), len_(len), pos_(0), error_(false) {}

    size_t rem() const { return pos_ <= len_ ? len_ - pos_ : 0; }
    size_t len() const { return len_; }
    size_t pos() const { return pos_; }
    void set_pos(size_t n) { pos_ = n; }
    bool error() const { return error_; }

    // Overflow-safe "pos + n <= len" test; also honours the error latch.
    bool can(size_t n) const {
        return !error_ && n <= len_ && pos_ <= len_ - n;
    }

    uint64_t le(size_t n) {
        uint64_t v = 0;
        if (n > 8 || !can(n)) { error_ = true; return 0; }
        for (size_t i = 0; i < n; ++i)
            v |= static_cast<uint64_t>(p_[pos_ + i]) << (8 * i);
        pos_ += n;
        return v;
    }

    // Read exactly n bytes; on failure latch the error and hand back zeros.
    std::vector<uint8_t> raw(size_t n) {
        if (!can(n)) { error_ = true; return std::vector<uint8_t>(n, 0); }
        std::vector<uint8_t> v(p_ + pos_, p_ + pos_ + n);
        pos_ += n;
        return v;
    }

    // Read exactly n bytes as a string truncated to cap. The reader always
    // advances by n (alignment is preserved) even when the result is clipped.
    std::string strn(size_t n, size_t cap) {
        if (cap == 0) return std::string();
        if (!can(n)) { error_ = true; return std::string(); }
        size_t m = (n < cap - 1) ? n : cap - 1;
        std::string s(reinterpret_cast<const char*>(p_ + pos_), m);
        pos_ += n;
        return s;
    }

    void skip(size_t n) {
        if (!can(n)) { error_ = true; pos_ = len_; }
        else pos_ += n;
    }

    // MySQL length-encoded integer. 0xFB (NULL) and 0xFF (reserved) are not
    // valid lengths where a length is required, so they latch the error.
    uint64_t lenenc() {
        uint8_t b = static_cast<uint8_t>(le(1));
        if (b < 0xFB) return b;
        if (b == 0xFC) return le(2);
        if (b == 0xFD) return le(3);
        if (b == 0xFE) return le(8);
        error_ = true;
        return 0;
    }

private:
    const uint8_t* p_;
    size_t len_;
    size_t pos_;
    bool error_;
};
} // namespace

// === [2] CRC-32 ===
// IEEE 802.3 / zlib, public for unit tests.
// Standard vector: crc32("123456789") == 0xCBF43926.
uint32_t crc32(const uint8_t* data, size_t size) {
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < size; ++i) {
        crc ^= data[i];
        for (int k = 0; k < 8; ++k) {
            uint32_t mask = 0u - (crc & 1u);
            crc = (crc >> 1) ^ (0xEDB88320u & mask);
        }
    }
    return ~crc;
}

namespace {
// Little-endian peek over an already validated, CRC-sized region.
uint32_t peek_le32(const uint8_t* p) {
    return static_cast<uint32_t>(p[0])
         | (static_cast<uint32_t>(p[1]) << 8)
         | (static_cast<uint32_t>(p[2]) << 16)
         | (static_cast<uint32_t>(p[3]) << 24);
}
} // namespace

// === [3] Serializer ===
// Bounded canonical JSONL builder (fixed key order, no spaces).
namespace {
class Serializer {
public:
    Serializer() : len_(0), overflow_(false) { buf_[0] = '\0'; }

    bool overflow() const { return overflow_; }
    std::string str() const { return std::string(buf_, len_); }

    void putc(char c) {
        if (overflow_) return;
        if (len_ + 1 >= kLineCap) { overflow_ = true; return; }
        buf_[len_++] = c;
        buf_[len_] = '\0';
    }

    void puts(const char* s) { while (*s) putc(*s++); }
    void puts(const std::string& s) { for (char c : s) putc(c); }

    // Append a printf-style fragment; set overflow if it would not fit.
    void printf(const char* fmt, ...) {
        if (overflow_) return;
        size_t avail = kLineCap - len_;
        va_list ap;
        va_start(ap, fmt);
        int n = std::vsnprintf(buf_ + len_, avail, fmt, ap);
        va_end(ap);
        if (n < 0 || static_cast<size_t>(n) >= avail) { overflow_ = true; return; }
        len_ += static_cast<size_t>(n);
    }

    void num(long long v) { printf("%lld", v); }

    // Minimal JSON string escaping: quotes, backslash, control characters.
    void json_str(const std::string& s) {
        putc('"');
        for (unsigned char c : s) {
            switch (c) {
            case '"':  puts("\\\""); break;
            case '\\': puts("\\\\"); break;
            case '\n': puts("\\n");  break;
            case '\r': puts("\\r");  break;
            case '\t': puts("\\t");  break;
            default:
                if (c < 0x20) printf("\\u%04x", static_cast<unsigned>(c));
                else          putc(static_cast<char>(c));
            }
        }
        putc('"');
    }

private:
    char buf_[kLineCap];
    size_t len_;
    bool overflow_;
};
} // namespace

// === [4] SchemaRegistry ===
// table_id -> TableSchema, with a per-file lifetime.
namespace {
struct TableSchema {
    uint64_t table_id = 0;
    std::string db;
    std::string table;
    int column_count = 0;
    std::vector<uint8_t> column_types;
    std::vector<int> varchar_len_bytes; // 1 or 2 length-prefix bytes
    int nullable_count = 0;             // popcount of null bitmap
};

class SchemaRegistry {
public:
    // Insert or replace by table_id; bounded to kMaxTables entries.
    void put(const TableSchema& e) {
        for (auto& x : entries_) {
            if (x.table_id == e.table_id) { x = e; return; }
        }
        if (entries_.size() < kMaxTables) entries_.push_back(e);
    }

    // Returns nullptr when the table_id is unknown.
    const TableSchema* get(uint64_t table_id) const {
        for (const auto& x : entries_)
            if (x.table_id == table_id) return &x;
        return nullptr;
    }

private:
    std::vector<TableSchema> entries_;
};
} // namespace

// === [5] RowDecoder ===
// Decode a RowsEventV2 row sequence against a registered TableSchema.
namespace {
class RowDecoder {
public:
    // Decode one column value and append it to the JSON builder.
    static Status decode_value(ByteReader& r, const TableSchema& s, int col,
                               bool is_null, Serializer& b) {
        if (is_null) { b.puts("null"); return Status::Ok; }

        switch (s.column_types[col]) {
        case kTypeLonglong: {
            int64_t v = static_cast<int64_t>(r.le(8));
            b.num(static_cast<long long>(v));
            break;
        }
        case kTypeLong: {
            int32_t v = static_cast<int32_t>(static_cast<uint32_t>(r.le(4)));
            b.num(static_cast<long long>(v));
            break;
        }
        case kTypeVarchar: {
            int lb = s.varchar_len_bytes[col];
            if (lb != 1 && lb != 2) return Status::Unsupported;
            uint64_t slen = r.le(static_cast<size_t>(lb));
            if (slen > kVarcharCap - 1) return Status::Unsupported;
            std::string val = r.strn(static_cast<size_t>(slen), kVarcharCap);
            b.json_str(val);
            break;
        }
        default:
            return Status::Unsupported;
        }
        return r.error() ? Status::Truncated : Status::Ok;
    }

    // Emit the "rows" array. present_bitmap tells which columns carry values;
    // UPDATE events carry two bitmaps but the second is implicitly handled by
    // reading a second row.
    static Status decode_rows(ByteReader& r, const TableSchema& s,
                              uint64_t present_bitmap, Serializer& b) {
        int nb_size = (s.nullable_count + 7) / 8;
        int rowno = 0;

        b.puts(",\"rows\":[");

        while (r.rem() > 0 && !r.error()) {
            if (nb_size > 8) return Status::Unsupported;
            uint64_t null_bitmap = r.le(static_cast<size_t>(nb_size));
            if (r.error()) break;

            if (rowno) b.putc(',');
            b.putc('[');
            int first = 1;
            for (int i = 0; i < s.column_count; ++i) {
                if (!(present_bitmap & (1ULL << i))) continue;
                if (!first) b.putc(',');
                first = 0;
                Status st = decode_value(r, s, i,
                                         (null_bitmap & (1ULL << i)) != 0, b);
                if (st != Status::Ok) return st;
                if (r.error()) return Status::Truncated;
            }
            b.putc(']');
            ++rowno;
        }
        b.puts("]}");
        return r.error() ? Status::Truncated : Status::Ok;
    }
};
} // namespace

// === [6] EventParser ===
// Header decoding, framing, and one named handler per event kind.
namespace {
const char* rows_name(uint8_t t) {
    if (t == kEvWriteRowsV2)  return "WRITE_ROWS_EVENT_V2";
    if (t == kEvUpdateRowsV2) return "UPDATE_ROWS_EVENT_V2";
    if (t == kEvDeleteRowsV2) return "DELETE_ROWS_EVENT_V2";
    return "ROWS_EVENT_V2";
}

class EventParser {
public:
    // Dispatch a single verified event body to its named handler.
    Status dispatch(const EventHeader& h, const uint8_t* body, size_t body_len,
                    Serializer& b) {
        ByteReader r(body, body_len);
        switch (h.event_type) {
        case kEvFormatDesc:
            return parse_fde(r, h, body_len, body, b);
        case kEvGtid:
            return parse_gtid(r, h, b);
        case kEvQuery:
            return parse_query(r, h, b);
        case kEvRowsQuery:
            return parse_rows_query(r, h, b);
        case kEvTableMap:
            return parse_table_map(r, h, b);
        case kEvWriteRowsV2:
        case kEvUpdateRowsV2:
        case kEvDeleteRowsV2:
            return parse_rows_v2(r, h, b);
        case kEvXid:
            return parse_xid(r, h, b);
        case kEvRotate:
            return parse_rotate(r, h, b);
        default: // UNKNOWN -> safe skip, emit a stable one-line record
            return parse_unknown(h, b);
        }
    }

private:
    // FORMAT_DESCRIPTION_EVENT.
    Status parse_fde(ByteReader& r, const EventHeader& h, size_t body_len,
                     const uint8_t* body, Serializer& b) {
        if (body_len < 2 + 50 + 1) return Status::Truncated;
        uint16_t binlog_version = static_cast<uint16_t>(r.le(2));
        std::vector<uint8_t> version_raw = r.raw(50);
        std::string server_version;
        for (size_t k = 0; k < version_raw.size() && version_raw[k]; ++k)
            server_version.push_back(static_cast<char>(version_raw[k]));
        uint8_t checksum_alg = body[body_len - 1];

        b.puts("{\"type\":\"FORMAT_DESCRIPTION_EVENT\",\"timestamp\":");
        b.num(h.timestamp);
        b.puts(",\"binlog_version\":");
        b.num(binlog_version);
        b.puts(",\"server_version\":");
        b.json_str(server_version);
        b.puts(",\"checksum_alg\":");
        b.num(checksum_alg);
        b.putc('}');
        return r.error() ? Status::Truncated : Status::Ok;
    }

    // GTID_LOG_EVENT.
    Status parse_gtid(ByteReader& r, const EventHeader& h, Serializer& b) {
        static const char hex[] = "0123456789abcdef";
        r.le(1); // flags
        std::vector<uint8_t> sid = r.raw(16);
        uint64_t gno = r.le(8);
        if (r.error()) return Status::Truncated;
        std::string sidhex;
        for (size_t i = 0; i < sid.size(); ++i) {
            sidhex.push_back(hex[sid[i] >> 4]);
            sidhex.push_back(hex[sid[i] & 0x0f]);
        }

        b.puts("{\"type\":\"GTID_LOG_EVENT\",\"timestamp\":");
        b.num(h.timestamp);
        b.puts(",\"gno\":");
        b.num(static_cast<long long>(gno));
        b.puts(",\"sid\":");
        b.json_str(sidhex);
        b.putc('}');
        return Status::Ok;
    }

    // QUERY_EVENT.
    Status parse_query(ByteReader& r, const EventHeader& h, Serializer& b) {
        r.le(4); // thread_id
        r.le(4); // exec_time
        uint8_t db_len = static_cast<uint8_t>(r.le(1));
        r.le(2);       // error_code
        uint16_t sv_len = static_cast<uint16_t>(r.le(2));
        r.skip(sv_len); // status_vars
        std::string db = r.strn(db_len, kNameCap);
        r.le(1);        // trailing NUL after db
        std::string query = r.strn(r.rem(), kQueryCap);
        if (r.error()) return Status::Truncated;

        b.puts("{\"type\":\"QUERY_EVENT\",\"timestamp\":");
        b.num(h.timestamp);
        b.puts(",\"db\":");
        b.json_str(db);
        b.puts(",\"query\":");
        b.json_str(query);
        b.putc('}');
        return Status::Ok;
    }

    // ROWS_QUERY_LOG_EVENT.
    Status parse_rows_query(ByteReader& r, const EventHeader& h, Serializer& b) {
        uint64_t len = r.lenenc();
        if (r.error()) return Status::Truncated;
        std::string q = r.strn(static_cast<size_t>(len), kQueryCap);
        if (r.error()) return Status::Truncated;

        b.puts("{\"type\":\"ROWS_QUERY_LOG_EVENT\",\"timestamp\":");
        b.num(h.timestamp);
        b.puts(",\"query\":");
        b.json_str(q);
        b.putc('}');
        return Status::Ok;
    }

    // TABLE_MAP_EVENT: register the schema, then append its JSON.
    Status parse_table_map(ByteReader& r, const EventHeader& h, Serializer& b) {
        TableSchema s;
        s.table_id = r.le(6);
        r.le(2); // flags
        uint8_t db_len = static_cast<uint8_t>(r.le(1));
        std::string db = r.strn(db_len, kNameCap);
        r.le(1); // NUL
        uint8_t table_len = static_cast<uint8_t>(r.le(1));
        std::string table = r.strn(table_len, kNameCap);
        r.le(1); // NUL
        uint64_t cc = r.lenenc();
        if (r.error()) return Status::Truncated;
        if (cc == 0 || cc > kMaxCols) return Status::Unsupported;
        s.column_count = static_cast<int>(cc);
        s.column_types.assign(s.column_count, 0);
        s.varchar_len_bytes.assign(s.column_count, 0);
        for (int i = 0; i < s.column_count; ++i)
            s.column_types[i] = static_cast<uint8_t>(r.le(1));

        uint64_t md_len = r.lenenc();
        size_t md_start = r.pos();
        if (r.error() || md_len > r.len() ||
            md_start > r.len() - static_cast<size_t>(md_len))
            return Status::Truncated;

        for (int i = 0; i < s.column_count; ++i) {
            if (s.column_types[i] == kTypeVarchar) {
                if (r.pos() + 2 > md_start + static_cast<size_t>(md_len))
                    return Status::Truncated;
                uint16_t maxlen = static_cast<uint16_t>(r.le(2));
                s.varchar_len_bytes[i] = (maxlen > 255) ? 2 : 1;
            }
        }
        r.set_pos(md_start + static_cast<size_t>(md_len)); // skip extra metadata

        size_t nb = (static_cast<size_t>(s.column_count) + 7) / 8;
        if (nb > 8) return Status::Unsupported;
        uint64_t null_bitmap = r.le(nb);
        for (int i = 0; i < s.column_count; ++i)
            if (null_bitmap & (1ULL << i)) ++s.nullable_count;
        if (r.error()) return Status::Truncated;

        s.db = db;
        s.table = table;
        reg_.put(s);

        b.puts("{\"type\":\"TABLE_MAP_EVENT\",\"timestamp\":");
        b.num(h.timestamp);
        b.puts(",\"table_id\":");
        b.num(static_cast<long long>(s.table_id));
        b.puts(",\"db\":");
        b.json_str(s.db);
        b.puts(",\"table\":");
        b.json_str(s.table);
        b.puts(",\"column_count\":");
        b.num(s.column_count);
        b.puts(",\"column_types\":[");
        for (int i = 0; i < s.column_count; ++i) {
            if (i) b.putc(',');
            b.num(s.column_types[i]);
        }
        b.puts("]}");
        return Status::Ok;
    }

    // WRITE/UPDATE/DELETE_ROWS_EVENT_V2.
    Status parse_rows_v2(ByteReader& r, const EventHeader& h, Serializer& b) {
        uint64_t table_id = r.le(6);
        r.le(2); // flags
        uint16_t extra_len = static_cast<uint16_t>(r.le(2)); // includes its own 2 bytes
        if (extra_len < 2) return Status::Unsupported;
        r.skip(static_cast<size_t>(extra_len - 2));
        uint64_t cc = r.lenenc();
        if (r.error()) return Status::Truncated;
        if (cc == 0 || cc > kMaxCols) return Status::Unsupported;
        size_t bm_size = static_cast<size_t>((cc + 7) / 8);
        if (bm_size > 8) return Status::Unsupported;
        uint64_t present_bitmap = r.le(bm_size);
        if (h.event_type == kEvUpdateRowsV2)
            r.le(bm_size); // before/after bitmap (equal here)
        if (r.error()) return Status::Truncated;

        const TableSchema* s = reg_.get(table_id);
        if (!s) return Status::NoSchema;

        b.puts("{\"type\":\"");
        b.puts(rows_name(h.event_type));
        b.puts("\",\"timestamp\":");
        b.num(h.timestamp);
        b.puts(",\"table_id\":");
        b.num(static_cast<long long>(table_id));
        b.puts(",\"db\":");
        b.json_str(s->db);
        b.puts(",\"table\":");
        b.json_str(s->table);
        return RowDecoder::decode_rows(r, *s, present_bitmap, b);
    }

    // XID_EVENT.
    Status parse_xid(ByteReader& r, const EventHeader& h, Serializer& b) {
        uint64_t xid = r.le(8);
        if (r.error()) return Status::Truncated;
        b.puts("{\"type\":\"XID_EVENT\",\"timestamp\":");
        b.num(h.timestamp);
        b.puts(",\"xid\":");
        b.num(static_cast<long long>(xid));
        b.putc('}');
        return Status::Ok;
    }

    // ROTATE_EVENT.
    Status parse_rotate(ByteReader& r, const EventHeader& h, Serializer& b) {
        uint64_t position = r.le(8);
        std::string next_file = r.strn(r.rem(), kNextFileCap);
        if (r.error()) return Status::Truncated;
        b.puts("{\"type\":\"ROTATE_EVENT\",\"timestamp\":");
        b.num(h.timestamp);
        b.puts(",\"position\":");
        b.num(static_cast<long long>(position));
        b.puts(",\"next_file\":");
        b.json_str(next_file);
        b.putc('}');
        return Status::Ok;
    }

    // UNKNOWN -> stable one-line record; the body is intentionally not read.
    Status parse_unknown(const EventHeader& h, Serializer& b) {
        b.puts("{\"type\":\"UNKNOWN\",\"timestamp\":");
        b.num(h.timestamp);
        b.puts(",\"type_id\":");
        b.num(h.event_type);
        b.puts(",\"event_size\":");
        b.num(h.event_size);
        b.putc('}');
        return Status::Ok;
    }

    SchemaRegistry reg_;
};
} // namespace

// Decode a single 19-byte little-endian event header (public API).
Status parse_header(const uint8_t* data, size_t size, EventHeader& h) {
    if (!data || size < kHeaderSize) return Status::Truncated;
    ByteReader r(data, size);
    h.timestamp     = static_cast<uint32_t>(r.le(4));
    h.event_type    = static_cast<uint8_t>(r.le(1));
    h.server_id     = static_cast<uint32_t>(r.le(4));
    h.event_size    = static_cast<uint32_t>(r.le(4));
    h.next_position = static_cast<uint32_t>(r.le(4));
    h.flags         = static_cast<uint16_t>(r.le(2));
    return r.error() ? Status::Truncated : Status::Ok;
}

// === [7] Public API ===
// Whole-buffer parser: verify magic, frame/verify each event, dispatch, emit.
Status parse_buffer(const uint8_t* data, size_t size, std::ostream& out) {
    if (!data || size < kMagicSize) return Status::Invalid;
    if (std::memcmp(data, kMagic, kMagicSize) != 0) return Status::Invalid;

    EventParser parser; // owns the per-file SchemaRegistry
    size_t pos = kMagicSize;

    while (pos < size) {
        if (size - pos < kHeaderSize) return Status::Truncated;

        EventHeader h = {};
        if (parse_header(data + pos, kHeaderSize, h) != Status::Ok)
            return Status::Truncated;

        size_t es = h.event_size;
        if (es < kHeaderSize + kCrcSize || es > kMaxEventSize || es > size - pos)
            return Status::Truncated;

        const uint8_t* full = data + pos;
        // Every event in the controlled subset carries CRC32 (the FDE declares
        // checksum_alg=1), so it is verified unconditionally here.
        uint32_t stored = peek_le32(full + es - kCrcSize);
        uint32_t calc = crc32(full, es - kCrcSize);
        if (stored != calc) return Status::Checksum;

        const uint8_t* body = full + kHeaderSize;
        size_t body_len = es - kHeaderSize - kCrcSize;
        Serializer b;
        Status st = parser.dispatch(h, body, body_len, b);
        if (st != Status::Ok) return st;
        if (b.overflow()) return Status::Invalid;

        out << b.str() << '\n';
        pos += es;
    }
    return Status::Ok;
}

} // namespace mysqlbinlog
