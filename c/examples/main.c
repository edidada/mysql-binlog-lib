#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mysqlbinlog.h"

static void usage(const char *prog)
{
    fprintf(stderr, "Usage: %s --file <path> [--format jsonl]\n", prog);
}

int main(int argc, char **argv)
{
    const char *file = NULL;
    const char *format = "jsonl";
    int i;
    FILE *f;
    long sz;
    uint8_t *buf;
    size_t got;
    mb_status st;

    for (i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--help")) { usage(argv[0]); return 0; }
        else if (!strcmp(argv[i], "--file") && i + 1 < argc) file = argv[++i];
        else if (!strcmp(argv[i], "--format") && i + 1 < argc) format = argv[++i];
        else { fprintf(stderr, "unknown argument: %s\n", argv[i]); usage(argv[0]); return 2; }
    }
    if (!file) { usage(argv[0]); return 2; }
    if (strcmp(format, "jsonl")) { fprintf(stderr, "only --format jsonl is supported\n"); return 2; }

    f = fopen(file, "rb");
    if (!f) { fprintf(stderr, "cannot open file: %s\n", file); return 2; }
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return 2; }
    sz = ftell(f);
    if (sz < 0 || fseek(f, 0, SEEK_SET) != 0) { fclose(f); return 2; }
    buf = (uint8_t *)malloc((size_t)sz ? (size_t)sz : 1);
    if (!buf) { fclose(f); return 2; }
    got = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    if (got != (size_t)sz) { free(buf); return 2; }

    st = mb_parse_buffer(buf, (size_t)sz, stdout);
    free(buf);
    if (st != MB_OK) { fprintf(stderr, "parse failed: status=%d\n", (int)st); return 1; }
    return 0;
}
