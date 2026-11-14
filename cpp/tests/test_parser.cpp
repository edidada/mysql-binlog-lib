#include <cassert>
#include <cstdint>
#include <iostream>
#include <sstream>
#include "mysqlbinlog.hpp"

using namespace mysqlbinlog;

static void put_le(uint8_t* p, uint64_t v, int n)
{
    for (int i = 0; i < n; ++i) p[i] = (uint8_t)(v >> (8 * i));
}

int main()
{
    assert(crc32((const uint8_t*)"123456789", 9) == 0xCBF43926u);

    uint8_t h[19];
    put_le(h, 1700000000u, 4);
    h[4] = 15;
    put_le(h + 5, 1, 4);
    put_le(h + 9, 119, 4);
    put_le(h + 13, 123, 4);
    put_le(h + 17, 0, 2);

    EventHeader out;
    assert(parse_header(h, 19, out) == Status::Ok);
    assert(out.timestamp == 1700000000u);
    assert(out.event_type == 15);
    assert(out.server_id == 1);
    assert(out.event_size == 119);
    assert(out.next_position == 123);
    assert(out.flags == 0);

    assert(parse_header(h, 10, out) == Status::Truncated);

    {
        uint8_t bad[4] = { 0, 0, 0, 0 };
        std::ostringstream oss;
        assert(parse_buffer(bad, 4, oss) == Status::Invalid);
    }

    std::cout << "cpp unit tests ok\n";
    return 0;
}
