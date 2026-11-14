#include "mysqlbinlog.hpp"

#include <cstdio>
#include <ostream>
#include <string>
#include <vector>

namespace mysqlbinlog {
namespace {

// ---- ByteReader ----------------------------------------------------------
class Reader {
public:
    Reader(const uint8_t* p, size_t len)
        : p_(p), len_(len), pos_(0), error_(false) {}

    size_t rem() const { return pos_ <= len_ ? len_ - pos_ : 0; }
    size_t pos() const { return pos_; }
    void set_pos(size_t n) { pos_ = n; }
    bool error() const { return error_; }

    uint64_t le(int n) {
        uint64_t v = 0;
        if (n < 0 || n > 8 || pos_ + (size_t)n > len_) { error_ = true; return 0; }
        for (int i = 0; i < n; ++i)
            v |= ((uint64_t)p_[pos_ + (size_t)i]) << (8 * i);
        pos_ += (size_t)n;
        return v;
    }

    void skip(size_t n) {
        if (pos_ + n > len_) { error_ = true; pos_ = len_; }
        else pos_ += n;
    }

    std::string strn(size_t n) {
        if (pos_ + n > len_) { error_ = true; return {}; }
        std::string s(reinterpret_cast<const char*>(p_ + pos_), n);
        pos_ += n;
        return s;
    }

    std::vector<uint8_t> raw(size_t n) {
        if (pos_ + n > len_) { error_ = true; return {}; }
        std::vector<uint8_t> v(p_ + pos_, p_ + pos_ + n);
        pos_ += n;
        return v;
    }

    uint64_t lenenc(int& is_null) {
        is_null = 0;
        uint8_t b = (uint8_t)le(1);
        if (b < 0xFB) return b;
        if (b == 0xFB) { is_null = 1; return 0; }
        if (b == 0xFC) return le(2);
        if (b == 0xFD) return le(3);
        if (b == 0xFE) return le(8);
        return 0;
    }

private:
    const uint8_t* p_;
    size_t len_;
    size_t pos_;
    bool error_;
};

uint64_t peek_le(const uint8_t* p, int n) {
    uint64_t v = 0;
    for (int i = 0; i < n; ++i) v |= ((uint64_t)p[i]) << (8 * i);
    return v;
}

// ---- Canonical JSON helpers ---------------------------------------------
template <typename T>
std::string num(T v) { return std::to_string(static_cast<long long>(v)); }

void append_json_str(std::string& o, const std::string& s) {
    o.push_back('"');
    for (unsigned char c : s) {
        switch (c) {
        case '"':  o += "\\\""; break;
        case '\\': o += "\\\\"; break;
        case '\n': o += "\\n"; break;
        case '\r': o += "\\r"; break;
        case '\t': o += "\\t"; break;
        default:
            if (c < 0x20) {
                char buf[8];
                std::snprintf(buf, sizeof(buf), "\\u%04x", (unsigned)c);
                o += buf;
            } else {
                o.push_back((char)c);
            }
        }
    }
    o.push_back('"');
}

// ---- SchemaRegistry ------------------------------------------------------
struct Schema {
    uint64_t table_id = 0;
    std::string db, table;
    int column_count = 0;
    std::vector<uint8_t> column_types;
    std::vector<int> varchar_len_bytes;
    int nullable_count = 0;
};

struct Registry {
    std::vector<Schema> v;
    void put(const Schema& s) {
        for (auto& e : v) if (e.table_id == s.table_id) { e = s; return; }
        v.push_back(s);
    }
    Schema* get(uint64_t id) {
        for (auto& e : v) if (e.table_id == id) return &e;
        return nullptr;
    }
};

const char* rows_name(uint8_t t) {
    if (t == 30) return "WRITE_ROWS_EVENT_V2";
    if (t == 31) return "UPDATE_ROWS_EVENT_V2";
    if (t == 32) return "DELETE_ROWS_EVENT_V2";
    return "ROWS_EVENT_V2";
}

} // namespace

// ---- Public API ----------------------------------------------------------
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

Status parse_header(const uint8_t* data, size_t size, EventHeader& h) {
    if (!data || size < 19) return Status::Truncated;
    Reader r(data, size);
    h.timestamp     = (uint32_t)r.le(4);
    h.event_type    = (uint8_t)r.le(1);
    h.server_id     = (uint32_t)r.le(4);
    h.event_size    = (uint32_t)r.le(4);
    h.next_position = (uint32_t)r.le(4);
    h.flags         = (uint16_t)r.le(2);
    return r.error() ? Status::Truncated : Status::Ok;
}

Status parse_buffer(const uint8_t* data, size_t size, std::ostream& out) {
    if (!data || size < 4) return Status::Invalid;
    if (!(data[0] == 0xFE && data[1] == 'b' && data[2] == 'i' && data[3] == 'n'))
        return Status::Invalid;

    Registry reg;
    size_t pos = 4; // skip magic
    while (pos < size) {
        if (pos + 19 > size) return Status::Truncated;
        EventHeader h;
        if (parse_header(data + pos, 19, h) != Status::Ok) return Status::Truncated;
        size_t es = h.event_size;
        if (es < 19 + 4 || pos + es > size) return Status::Truncated;

        const uint8_t* full = data + pos;
        // Controlled subset: every event carries CRC32 (FDE declares alg=1).
        uint32_t stored = (uint32_t)peek_le(full + es - 4, 4);
        uint32_t calc = crc32(full, es - 4);
        if (stored != calc) return Status::Checksum;

        const uint8_t* body = full + 19;
        size_t body_len = es - 19 - 4;
        Reader r(body, body_len);
        std::string line;
        Status st = Status::Ok;
        int is_null = 0;

        switch (h.event_type) {
        case 15: { // FORMAT_DESCRIPTION_EVENT
            uint16_t bv = (uint16_t)r.le(2);
            auto tmp = r.raw(50);
            std::string sv;
            for (size_t k = 0; k < tmp.size() && tmp[k]; ++k) sv.push_back((char)tmp[k]);
            uint8_t alg = body[body_len - 1];
            line += "{\"type\":\"FORMAT_DESCRIPTION_EVENT\",\"timestamp\":" + num(h.timestamp)
                  + ",\"binlog_version\":" + num(bv) + ",\"server_version\":";
            append_json_str(line, sv);
            line += ",\"checksum_alg\":" + num(alg) + "}";
            break;
        }
        case 33: { // GTID_LOG_EVENT
            r.le(1); // flags
            auto sid = r.raw(16);
            uint64_t gno = r.le(8);
            static const char hex[] = "0123456789abcdef";
            std::string sh;
            for (auto b : sid) { sh.push_back(hex[b >> 4]); sh.push_back(hex[b & 0x0f]); }
            line += "{\"type\":\"GTID_LOG_EVENT\",\"timestamp\":" + num(h.timestamp)
                  + ",\"gno\":" + num(gno) + ",\"sid\":";
            append_json_str(line, sh);
            line += "}";
            break;
        }
        case 2: { // QUERY_EVENT
            r.le(4); // thread_id
            r.le(4); // exec_time
            uint8_t dbl = (uint8_t)r.le(1);
            r.le(2);  // error_code
            uint16_t svl = (uint16_t)r.le(2);
            r.skip(svl); // status_vars
            std::string db = r.strn(dbl);
            r.le(1); // trailing NUL
            std::string query = r.strn(r.rem());
            line += "{\"type\":\"QUERY_EVENT\",\"timestamp\":" + num(h.timestamp) + ",\"db\":";
            append_json_str(line, db);
            line += ",\"query\":";
            append_json_str(line, query);
            line += "}";
            break;
        }
        case 29: { // ROWS_QUERY_LOG_EVENT
            uint64_t len = r.lenenc(is_null);
            std::string q = r.strn((size_t)len);
            line += "{\"type\":\"ROWS_QUERY_LOG_EVENT\",\"timestamp\":" + num(h.timestamp)
                  + ",\"query\":";
            append_json_str(line, q);
            line += "}";
            break;
        }
        case 19: { // TABLE_MAP_EVENT
            Schema s;
            s.table_id = r.le(6);
            r.le(2); // flags
            uint8_t dbl = (uint8_t)r.le(1);
            s.db = r.strn(dbl);
            r.le(1); // NUL
            uint8_t tl = (uint8_t)r.le(1);
            s.table = r.strn(tl);
            r.le(1); // NUL
            int cc = (int)r.lenenc(is_null);
            s.column_count = cc;
            s.column_types.resize(cc);
            s.varchar_len_bytes.assign(cc, 0);
            for (int i = 0; i < cc; ++i) s.column_types[i] = (uint8_t)r.le(1);
            uint64_t mdlen = r.lenenc(is_null);
            size_t mdstart = r.pos();
            for (int i = 0; i < cc; ++i) {
                if (s.column_types[i] == 15) {
                    uint16_t mx = (uint16_t)r.le(2);
                    s.varchar_len_bytes[i] = (mx > 255) ? 2 : 1;
                }
            }
            r.set_pos(mdstart + (size_t)mdlen);
            int nb = (cc + 7) / 8;
            uint64_t nullbm = r.le(nb);
            int nullable = 0;
            for (int i = 0; i < cc; ++i) if (nullbm & (1ULL << i)) ++nullable;
            s.nullable_count = nullable;
            reg.put(s);

            line += "{\"type\":\"TABLE_MAP_EVENT\",\"timestamp\":" + num(h.timestamp)
                  + ",\"table_id\":" + num(s.table_id) + ",\"db\":";
            append_json_str(line, s.db);
            line += ",\"table\":";
            append_json_str(line, s.table);
            line += ",\"column_count\":" + num(cc) + ",\"column_types\":[";
            for (int i = 0; i < cc; ++i) { if (i) line += ','; line += num(s.column_types[i]); }
            line += "]}";
            break;
        }
        case 30: case 31: case 32: { // ROWS_EVENT_V2
            uint64_t tid = r.le(6);
            r.le(2); // flags
            uint16_t el = (uint16_t)r.le(2);
            if (el >= 2) r.skip((size_t)(el - 2));
            int cc = (int)r.lenenc(is_null);
            int bm = (cc + 7) / 8;
            uint64_t present1 = r.le(bm);
            if (h.event_type == 31) r.le(bm); // bitmap2, equal
            Schema* se = reg.get(tid);
            if (!se) { st = Status::NoSchema; break; }
            int nbs = (se->nullable_count + 7) / 8;

            line += "{\"type\":\"" + std::string(rows_name(h.event_type))
                  + "\",\"timestamp\":" + num(h.timestamp)
                  + ",\"table_id\":" + num(tid) + ",\"db\":";
            append_json_str(line, se->db);
            line += ",\"table\":";
            append_json_str(line, se->table);
            line += ",\"rows\":[";
            int rowno = 0;
            while (r.rem() > 0 && !r.error()) {
                uint64_t nullbm = r.le(nbs);
                int first = 1;
                if (r.error()) break;
                if (rowno) line += ',';
                line += '[';
                for (int i = 0; i < se->column_count; ++i) {
                    if (!(present1 & (1ULL << i))) continue;
                    if (!first) line += ',';
                    first = 0;
                    if (nullbm & (1ULL << i)) { line += "null"; continue; }
                    uint8_t t = se->column_types[i];
                    if (t == 8) {
                        int64_t v = (int64_t)r.le(8); line += num(v);
                    } else if (t == 3) {
                        int32_t v = (int32_t)(uint32_t)r.le(4); line += num(v);
                    } else if (t == 15) {
                        int lb = se->varchar_len_bytes[i]; if (lb == 0) lb = 1;
                        uint64_t slen = r.le(lb);
                        std::string val = r.strn((size_t)slen);
                        append_json_str(line, val);
                    } else {
                        st = Status::Unsupported; break;
                    }
                    if (r.error()) break;
                }
                line += ']';
                if (r.error() || st != Status::Ok) break;
                ++rowno;
            }
            line += "]}";
            break;
        }
        case 16: { // XID_EVENT
            uint64_t xid = r.le(8);
            line += "{\"type\":\"XID_EVENT\",\"timestamp\":" + num(h.timestamp)
                  + ",\"xid\":" + num(xid) + "}";
            break;
        }
        case 4: { // ROTATE_EVENT
            uint64_t position = r.le(8);
            std::string nf = r.strn(r.rem());
            line += "{\"type\":\"ROTATE_EVENT\",\"timestamp\":" + num(h.timestamp)
                  + ",\"position\":" + num(position) + ",\"next_file\":";
            append_json_str(line, nf);
            line += "}";
            break;
        }
        default: { // UNKNOWN -> safe skip
            line += "{\"type\":\"UNKNOWN\",\"timestamp\":" + num(h.timestamp)
                  + ",\"type_id\":" + num(h.event_type)
                  + ",\"event_size\":" + num(h.event_size) + "}";
            break;
        }
        }

        if (st != Status::Ok) return st;
        if (r.error()) return Status::Truncated;
        out << line << '\n';
        pos += es;
    }
    return Status::Ok;
}

} // namespace mysqlbinlog
