#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>
#include "mysqlbinlog.hpp"

using namespace mysqlbinlog;

static void usage(const char* prog)
{
    std::cerr << "Usage: " << prog << " --file <path> [--format jsonl]\n";
}

int main(int argc, char** argv)
{
    std::string file, format = "jsonl";
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--help") { usage(argv[0]); return 0; }
        else if (a == "--file" && i + 1 < argc) file = argv[++i];
        else if (a == "--format" && i + 1 < argc) format = argv[++i];
        else { std::cerr << "unknown argument: " << a << "\n"; usage(argv[0]); return 2; }
    }
    if (file.empty()) { usage(argv[0]); return 2; }
    if (format != "jsonl") { std::cerr << "only --format jsonl is supported\n"; return 2; }

    std::ifstream f(file, std::ios::binary);
    if (!f) { std::cerr << "cannot open file: " << file << "\n"; return 2; }
    std::vector<uint8_t> buf((std::istreambuf_iterator<char>(f)),
                             std::istreambuf_iterator<char>());

    Status st = parse_buffer(buf.data(), buf.size(), std::cout);
    if (st != Status::Ok) {
        std::cerr << "parse failed: status=" << static_cast<int>(st) << "\n";
        return 1;
    }
    return 0;
}
