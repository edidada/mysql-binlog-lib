#include <cassert>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>
#include "mysqlbinlog.hpp"

using namespace mysqlbinlog;

static const size_t kHeaderSize = 19;
static const size_t kCrcSize = 4;
static const size_t kMagicSize = 4;

static void put_le(uint8_t* p, uint64_t v, int n)
{
    for (int i = 0; i < n; ++i) p[i] = (uint8_t)(v >> (8 * i));
}

/* Build a minimal well-formed event (magic + one event + CRC32) and return
   the whole file as a byte vector. event_size is derived from body_len so the
   frame is always consistent. `crc_override` < 0 stores the correct CRC; any
   other value is stored verbatim (to exercise checksum failure). */
static std::vector<uint8_t> build_event(uint8_t event_type, int crc_override,
                                        const char* body, size_t body_len)
{
    std::vector<uint8_t> buf;
    uint32_t es = (uint32_t)(kHeaderSize + body_len + kCrcSize);

    const uint8_t magic[kMagicSize] = { 0xFE, 0x62, 0x69, 0x6E };
    buf.insert(buf.end(), magic, magic + kMagicSize);

    size_t frame_start = buf.size();
    std::vector<uint8_t> frame(kHeaderSize, 0);
    put_le(frame.data() + 0, 1, 4);            /* timestamp */
    frame[4] = event_type;
    put_le(frame.data() + 5, 1, 4);            /* server_id */
    put_le(frame.data() + 9, es, 4);           /* event_size */
    put_le(frame.data() + 13, es + kMagicSize, 4); /* next_position */
    put_le(frame.data() + 17, 0, 2);           /* flags */
    buf.insert(buf.end(), frame.begin(), frame.end());

    if (body_len) {
        const uint8_t* b = reinterpret_cast<const uint8_t*>(body);
        buf.insert(buf.end(), b, b + body_len);
    }

    /* CRC covers header + body (everything from frame_start up to here). */
    uint32_t crc = (crc_override < 0)
        ? crc32(buf.data() + frame_start, kHeaderSize + body_len)
        : (uint32_t)crc_override;
    uint8_t crcbuf[kCrcSize];
    put_le(crcbuf, crc, kCrcSize);
    buf.insert(buf.end(), crcbuf, crcbuf + kCrcSize);
    return buf;
}

static Status parse(const std::vector<uint8_t>& buf)
{
    std::ostringstream oss;
    return parse_buffer(buf.empty() ? nullptr : buf.data(), buf.size(), oss);
}

static int check_output(const std::vector<uint8_t>& buf, const std::string& expect)
{
    std::ostringstream oss;
    if (parse_buffer(buf.data(), buf.size(), oss) != Status::Ok) return 0;
    return oss.str() == expect;
}

int main()
{
    /* CRC-32 / IEEE standard vector. */
    assert(crc32((const uint8_t*)"123456789", 9) == 0xCBF43926u);

    /* 19-byte little-endian header, decoded field by field. */
    uint8_t h[19];
    put_le(h, 1700000000u, 4);
    h[4] = 15;
    put_le(h + 5, 1, 4);
    put_le(h + 9, 119, 4);
    put_le(h + 13, 123, 4);
    put_le(h + 17, 0, 2);

    EventHeader out{};
    assert(parse_header(h, 19, out) == Status::Ok);
    assert(out.timestamp == 1700000000u);
    assert(out.event_type == 15);
    assert(out.server_id == 1);
    assert(out.event_size == 119);
    assert(out.next_position == 123);
    assert(out.flags == 0);

    /* Truncated / null header must not crash, just report an error. */
    assert(parse_header(h, 10, out) == Status::Truncated);
    assert(parse_header(nullptr, 19, out) == Status::Truncated);

    /* Bad magic is rejected by the whole-buffer parser. */
    {
        uint8_t bad[4] = { 0x00, 0x00, 0x00, 0x00 };
        std::ostringstream oss;
        assert(parse_buffer(bad, 4, oss) == Status::Invalid);
        std::ostringstream oss2;
        assert(parse_buffer(nullptr, 0, oss2) == Status::Invalid);
    }

    /* A lone magic (no events) is a valid empty binlog -> OK, no output. */
    {
        uint8_t magic[4] = { 0xFE, 0x62, 0x69, 0x6E };
        std::ostringstream oss;
        assert(parse_buffer(magic, 4, oss) == Status::Ok);
        assert(oss.str().empty());
    }

    /* Truncated trailing header must be reported, not silently ignored. */
    {
        uint8_t partial[8] = { 0xFE, 0x62, 0x69, 0x6E, 1, 2, 3, 4 };
        std::ostringstream oss;
        assert(parse_buffer(partial, sizeof(partial), oss) == Status::Truncated);
    }

    /* event_size smaller than header+CRC is rejected before any read. */
    {
        uint8_t ev[27];
        std::memset(ev, 0, sizeof(ev));
        std::memcpy(ev, "\xFE\x62\x69\x6E", 4);
        put_le(ev + 4, 1, 4);
        ev[8] = 99;
        put_le(ev + 9, 1, 4);
        put_le(ev + 13, 20, 4);        /* 20 < 19 + 4 */
        std::ostringstream oss;
        assert(parse_buffer(ev, sizeof(ev), oss) == Status::Truncated);
    }

    /* A valid UNKNOWN event is safely skipped and emitted as one JSON line. */
    {
        std::vector<uint8_t> ev = build_event(99, -1, "abc", 3);
        assert(ev.size() == kMagicSize + 26); /* magic + 19 + body(3) + CRC(4) */
        assert(parse(ev) == Status::Ok);
        assert(check_output(ev,
            "{\"type\":\"UNKNOWN\",\"timestamp\":1,\"type_id\":99,\"event_size\":26}\n"));
    }

    /* CRC mismatch is detected (mutated CRC byte, otherwise well-formed). */
    {
        std::vector<uint8_t> ev = build_event(99, 0, "abc", 3);
        assert(parse(ev) == Status::Checksum);
    }

    /* A corrupt event_size that claims more bytes than available. */
    {
        std::vector<uint8_t> ev = build_event(99, -1, "abc", 3);
        put_le(ev.data() + kMagicSize + 9, 1000, 4); /* event_size = 1000 */
        assert(parse(ev) == Status::Truncated);
    }

    /* An oversized event_size beyond the hard cap is rejected. */
    {
        std::vector<uint8_t> ev = build_event(99, -1, "abc", 3);
        put_le(ev.data() + kMagicSize + 9, 300u * 1024u * 1024u, 4);
        assert(parse(ev) == Status::Truncated);
    }

    std::cout << "cpp unit tests ok\n";
    return 0;
}
