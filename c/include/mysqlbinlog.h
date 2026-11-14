#ifndef MYSQLBINLOG_H
#define MYSQLBINLOG_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    MB_OK = 0,
    MB_ERR_INVALID = -1,
    MB_ERR_TRUNCATED = -2,
    MB_ERR_UNSUPPORTED = -3,
    MB_ERR_CHECKSUM = -4,
    MB_ERR_NO_SCHEMA = -5,
    MB_ERR_IO = -6
} mb_status;

typedef struct {
    uint32_t timestamp;
    uint8_t event_type;
    uint32_t server_id;
    uint32_t event_size;
    uint32_t next_position;
    uint16_t flags;
} mb_event_header;

/* Decode a single 19-byte little-endian event header. */
mb_status mb_parse_header(const uint8_t *data, size_t size, mb_event_header *h);

/* Standard CRC-32 (IEEE/zlib), exposed for unit tests. */
uint32_t mb_crc32(const uint8_t *data, size_t size);

/* Parse a whole binlog buffer; write canonical JSONL lines to `out`.
   Returns MB_OK or a negative mb_status. */
mb_status mb_parse_buffer(const uint8_t *data, size_t size, FILE *out);

#ifdef __cplusplus
}
#endif

#endif /* MYSQLBINLOG_H */
