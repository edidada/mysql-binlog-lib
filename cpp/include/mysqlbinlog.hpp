#ifndef MYSQLBINLOG_HPP
#define MYSQLBINLOG_HPP

#include <cstddef>
#include <cstdint>
#include <iosfwd>
#include <string>

namespace mysqlbinlog {

/*
 * Phase 1 offline parser (see docs/design.md). The public API below and the
 * canonical JSONL emitted by parse_buffer are a cross-language contract: the
 * other language implementations and fixtures/expected.jsonl rely on them.
 * Internals are layered as ByteReader / CRC32 / Serializer / SchemaRegistry /
 * RowDecoder / EventParser inside src/mysqlbinlog.cpp.
 */

enum class Status {
    Ok = 0,
    Invalid = -1,
    Truncated = -2,
    Unsupported = -3,
    Checksum = -4,
    NoSchema = -5,
    Io = -6
};

struct EventHeader {
    uint32_t timestamp;
    uint8_t event_type;
    uint32_t server_id;
    uint32_t event_size;
    uint32_t next_position;
    uint16_t flags;
};

Status parse_header(const uint8_t* data, size_t size, EventHeader& h);
uint32_t crc32(const uint8_t* data, size_t size);
Status parse_buffer(const uint8_t* data, size_t size, std::ostream& out);

} // namespace mysqlbinlog

#endif // MYSQLBINLOG_HPP
