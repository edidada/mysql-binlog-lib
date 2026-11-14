#include <assert.h>
#include <stdio.h>
#include "mysqlbinlog.h"

static void put_le(uint8_t *p, uint64_t v, int n)
{
    int i;
    for (i = 0; i < n; ++i) p[i] = (uint8_t)(v >> (8 * i));
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

    /* Truncated header must not crash, just report an error. */
    assert(mb_parse_header(h, 10, &out) == MB_ERR_TRUNCATED);

    /* Bad magic is rejected by the whole-buffer parser. */
    {
        uint8_t bad[4] = { 0x00, 0x00, 0x00, 0x00 };
        assert(mb_parse_buffer(bad, 4, stdout) == MB_ERR_INVALID);
    }

    printf("c unit tests ok\n");
    return 0;
}
