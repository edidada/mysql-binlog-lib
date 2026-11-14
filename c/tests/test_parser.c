#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "mysqlbinlog.h"

static void put_le(uint8_t *p, uint64_t v, int n)
{
    int i;
    for (i = 0; i < n; ++i) p[i] = (uint8_t)(v >> (8 * i));
}

/* Build a minimal well-formed event (magic + one event + CRC32) and return
   its total file size. event_size is derived from body_len so the frame is
   always consistent. `crc_override` < 0 stores the correct CRC; any other
   value is stored verbatim (to exercise checksum failure). */
static size_t build_event(uint8_t *buf, uint8_t event_type, int crc_override,
                          const char *body, size_t body_len)
{
    size_t pos = 0;
    uint32_t es = (uint32_t)(19 + body_len + 4);
    uint8_t *frame;
    uint32_t crc;

    memcpy(buf + pos, "\xFE\x62\x69\x6E", 4); pos += 4;
    frame = buf + pos;
    put_le(frame + 0, 1, 4);            /* timestamp */
    frame[4] = event_type;
    put_le(frame + 5, 1, 4);            /* server_id */
    put_le(frame + 9, es, 4);           /* event_size */
    put_le(frame + 13, es + 4, 4);      /* next_position (after magic) */
    put_le(frame + 17, 0, 2);           /* flags */
    pos += 19;
    if (body_len) { memcpy(buf + pos, body, body_len); pos += body_len; }
    crc = (crc_override < 0)
        ? mb_crc32(frame, 19 + body_len)
        : (uint32_t)crc_override;
    put_le(buf + pos, crc, 4); pos += 4;
    return pos;
}

int main(void)
{
    uint8_t h[19];
    mb_event_header out;

    /* CRC-32 / IEEE standard vector. */
    assert(mb_crc32((const uint8_t *)"123456789", 9) == 0xCBF43926u);

    /* 19-byte little-endian header, decoded field by field. */
    put_le(h, 1700000000u, 4);
    h[4] = 15;
    put_le(h + 5, 1, 4);
    put_le(h + 9, 119, 4);
    put_le(h + 13, 123, 4);
    put_le(h + 17, 0, 2);

    assert(mb_parse_header(h, 19, &out) == MB_OK);
    assert(out.timestamp == 1700000000u);
    assert(out.event_type == 15);
    assert(out.server_id == 1);
    assert(out.event_size == 119);
    assert(out.next_position == 123);
    assert(out.flags == 0);

    /* Truncated / null header must not crash, just report an error. */
    assert(mb_parse_header(h, 10, &out) == MB_ERR_TRUNCATED);
    assert(mb_parse_header(NULL, 19, &out) == MB_ERR_TRUNCATED);
    assert(mb_parse_header(h, 19, NULL) == MB_ERR_TRUNCATED);

    /* Bad magic is rejected by the whole-buffer parser. */
    {
        uint8_t bad[4] = { 0x00, 0x00, 0x00, 0x00 };
        assert(mb_parse_buffer(bad, 4, stdout) == MB_ERR_INVALID);
        assert(mb_parse_buffer(NULL, 0, stdout) == MB_ERR_INVALID);
    }

    /* A lone magic (no events) is a valid empty binlog -> OK, no output. */
    {
        uint8_t magic[4] = { 0xFE, 0x62, 0x69, 0x6E };
        assert(mb_parse_buffer(magic, 4, stdout) == MB_OK);
    }

    /* Truncated trailing header must be reported, not silently ignored. */
    {
        uint8_t partial[8] = { 0xFE, 0x62, 0x69, 0x6E, 1, 2, 3, 4 };
        assert(mb_parse_buffer(partial, sizeof(partial), stdout)
               == MB_ERR_TRUNCATED);
    }

    /* event_size smaller than header+CRC is rejected before any read. */
    {
        uint8_t ev[27];
        memset(ev, 0, sizeof(ev));
        memcpy(ev, "\xFE\x62\x69\x6E", 4);
        put_le(ev + 4, 1, 4);
        ev[8] = 99;
        put_le(ev + 9, 1, 4);
        put_le(ev + 13, 20, 4);        /* 20 < 19 + 4 */
        assert(mb_parse_buffer(ev, sizeof(ev), stdout) == MB_ERR_TRUNCATED);
    }

    /* A valid UNKNOWN event is safely skipped and emitted as one JSON line. */
    {
        uint8_t ev[64];
        size_t n = build_event(ev, 99, -1, "abc", 3);
        assert(n == 4 + 26);            /* magic + 19 + body(3) + CRC(4) */
        assert(mb_parse_buffer(ev, n, stdout) == MB_OK);
    }

    /* CRC mismatch is detected (mutated CRC byte, otherwise well-formed). */
    {
        uint8_t ev[64];
        size_t n = build_event(ev, 99, 0, "abc", 3);
        assert(mb_parse_buffer(ev, n, stdout) == MB_ERR_CHECKSUM);
    }

    /* A corrupt event_size that claims more bytes than available. */
    {
        uint8_t ev[64];
        size_t n = build_event(ev, 99, -1, "abc", 3);
        put_le(ev + 4 + 9, 1000, 4);   /* event_size = 1000, buffer is 30 */
        assert(mb_parse_buffer(ev, n, stdout) == MB_ERR_TRUNCATED);
    }

    printf("c unit tests ok\n");
    return 0;
}
