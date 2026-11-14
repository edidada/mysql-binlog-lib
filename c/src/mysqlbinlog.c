/*
 * mysqlbinlog.c - offline MySQL binlog parser (Phase 1 controlled subset).
 *
 * Layered structure (mirrors docs/design.md section 4):
 *
 *   [1] ByteReader     bounds-checked little-endian primitives
 *   [2] CRC-32         IEEE / zlib checksum
 *   [3] Serializer     canonical JSONL builder (fixed key order, no spaces)
 *   [4] SchemaRegistry table_id -> TableSchema
 *   [5] RowDecoder     decode RowsEventV2 rows using a registered schema
 *   [6] EventParser    frame/verify/dispatch events -> one JSONL line each
 *   [7] Public API     mb_parse_header / mb_crc32 / mb_parse_buffer
 *
 * The public API in include/mysqlbinlog.h and the emitted JSONL are a
 * contract with the other nine language implementations (fixtures/
 * expected.jsonl). Do not change either without a cross-language update.
 */

#include "mysqlbinlog.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

/* Protocol constants (docs/design.md section 2). */
#define MB_HEADER_SIZE       19u
#define MB_CRC_SIZE          4u
#define MB_MAGIC_SIZE        4u
#define MB_MAX_COLS          64
#define MB_MAX_TABLES        64
#define MB_MAX_EVENT_SIZE    (256u * 1024u * 1024u) /* defence against corrupt sizes */
#define MB_LINE_CAP          16384                    /* max single JSONL line */

/* Column type ids used by the controlled subset. */
#define MB_TYPE_LONG         3
#define MB_TYPE_LONGLONG     8
#define MB_TYPE_VARCHAR      15

/* Event type ids (docs/design.md section 3). */
#define MB_EV_QUERY          2
#define MB_EV_ROTATE         4
#define MB_EV_FORMAT_DESC    15
#define MB_EV_XID            16
#define MB_EV_TABLE_MAP      19
#define MB_EV_ROWS_QUERY     29
#define MB_EV_WRITE_ROWS_V2  30
#define MB_EV_UPDATE_ROWS_V2 31
#define MB_EV_DELETE_ROWS_V2 32
#define MB_EV_GTID           33

/* ================================================================== */
/* [1] ByteReader: every read is bounds-checked; r->error latches.      */
/* ================================================================== */
typedef struct {
    const uint8_t *p;
    size_t len;
    size_t pos;
    int error;
} reader;

static void rd_init(reader *r, const uint8_t *p, size_t len)
{
    r->p = p;
    r->len = len;
    r->pos = 0;
    r->error = 0;
}

static size_t rem(const reader *r)
{
    return r->pos <= r->len ? r->len - r->pos : 0;
}

/* Overflow-safe "pos + n <= len" test. */
static int rd_can(const reader *r, size_t n)
{
    return !r->error && n <= r->len && r->pos <= r->len - n;
}

static uint64_t rd_le(reader *r, size_t n)
{
    uint64_t v = 0;
    size_t i;

    if (n > 8 || !rd_can(r, n)) {
        r->error = 1;
        return 0;
    }
    for (i = 0; i < n; ++i)
        v |= ((uint64_t)r->p[r->pos + i]) << (8 * i);
    r->pos += n;
    return v;
}

static void rd_raw(reader *r, size_t n, uint8_t *dst)
{
    if (!rd_can(r, n)) {
        r->error = 1;
        if (dst) memset(dst, 0, n);
        return;
    }
    if (dst) memcpy(dst, r->p + r->pos, n);
    r->pos += n;
}

/* Read exactly n bytes as a NUL-terminated C string. The reader always
   advances by n (alignment is preserved) even if the string is truncated
   to fit cap. */
static void rd_strn(reader *r, size_t n, char *dst, size_t cap)
{
    size_t m;

    if (cap == 0) return;
    if (!rd_can(r, n)) {
        r->error = 1;
        dst[0] = '\0';
        return;
    }
    m = n < cap - 1 ? n : cap - 1;
    memcpy(dst, r->p + r->pos, m);
    dst[m] = '\0';
    r->pos += n;
}

static void rd_skip(reader *r, size_t n)
{
    if (!rd_can(r, n)) {
        r->error = 1;
        r->pos = r->len;
    } else {
        r->pos += n;
    }
}

/* MySQL length-encoded integer. Returns MB_ERR_UNSUPPORTED via r->error
   for the reserved 0xFF marker and for NULL (0xFB) where a length is
   required. */
static uint64_t rd_lenenc(reader *r)
{
    uint8_t b;

    b = (uint8_t)rd_le(r, 1);
    if (b < 0xFB) return b;
    if (b == 0xFC) return rd_le(r, 2);
    if (b == 0xFD) return rd_le(r, 3);
    if (b == 0xFE) return rd_le(r, 8);
    r->error = 1; /* 0xFB (NULL) or 0xFF (reserved) is not a valid length */
    return 0;
}

/* ================================================================== */
/* [2] CRC-32 (IEEE 802.3 / zlib), public for unit tests.               */
/* ================================================================== */
uint32_t mb_crc32(const uint8_t *data, size_t size)
{
    uint32_t crc = 0xFFFFFFFFu;
    size_t i;
    int k;

    for (i = 0; i < size; ++i) {
        crc ^= data[i];
        for (k = 0; k < 8; ++k) {
            uint32_t mask = 0u - (crc & 1u);
            crc = (crc >> 1) ^ (0xEDB88320u & mask);
        }
    }
    return ~crc;
}

/* Little-endian peek over an already validated, CRC-sized region. */
static uint32_t peek_le32(const uint8_t *p)
{
    return (uint32_t)p[0]
         | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16)
         | ((uint32_t)p[3] << 24);
}

/* ================================================================== */
/* [3] Serializer: bounded canonical JSONL builder.                     */
/* ================================================================== */
typedef struct {
    char *p;
    size_t cap;
    size_t len;
    int overflow;
} sb;

static void sb_init(sb *b, char *buf, size_t cap)
{
    b->p = buf;
    b->cap = cap;
    b->len = 0;
    b->overflow = 0;
    if (cap) buf[0] = '\0';
}

static void sb_putc(sb *b, char c)
{
    if (b->overflow) return;
    if (b->len + 1 >= b->cap) { b->overflow = 1; return; }
    b->p[b->len++] = c;
    b->p[b->len] = '\0';
}

static void sb_puts(sb *b, const char *s)
{
    while (*s) sb_putc(b, *s++);
}

static void sb_printf(sb *b, const char *fmt, ...)
{
    va_list ap;
    int n;
    size_t avail;

    if (b->overflow) return;
    avail = b->cap - b->len;
    va_start(ap, fmt);
    n = vsnprintf(b->p + b->len, avail, fmt, ap);
    va_end(ap);
    if (n < 0 || (size_t)n >= avail) { b->overflow = 1; return; }
    b->len += (size_t)n;
}

/* Minimal JSON string escaping: quotes, backslash, control characters. */
static void sb_json_str(sb *b, const char *s)
{
    sb_putc(b, '"');
    for (; *s; ++s) {
        unsigned char c = (unsigned char)*s;
        switch (c) {
        case '"':  sb_puts(b, "\\\""); break;
        case '\\': sb_puts(b, "\\\\"); break;
        case '\n': sb_puts(b, "\\n");  break;
        case '\r': sb_puts(b, "\\r");  break;
        case '\t': sb_puts(b, "\\t");  break;
        default:
            if (c < 0x20) sb_printf(b, "\\u%04x", (unsigned)c);
            else          sb_putc(b, (char)c);
        }
    }
    sb_putc(b, '"');
}

/* ================================================================== */
/* [4] SchemaRegistry: table_id -> TableSchema, per-file lifetime.       */
/* ================================================================== */
typedef struct {
    uint64_t table_id;
    char db[128];
    char table[128];
    int column_count;
    uint8_t column_types[MB_MAX_COLS];
    int varchar_len_bytes[MB_MAX_COLS]; /* 1 or 2 length-prefix bytes */
    int nullable_count;                 /* popcount of null bitmap */
} table_schema;

typedef struct {
    table_schema entries[MB_MAX_TABLES];
    int count;
} registry;

static void reg_init(registry *g)
{
    memset(g, 0, sizeof(*g));
}

static void reg_put(registry *g, const table_schema *e)
{
    int i;

    for (i = 0; i < g->count; ++i) {
        if (g->entries[i].table_id == e->table_id) {
            g->entries[i] = *e;
            return;
        }
    }
    if (g->count < MB_MAX_TABLES) g->entries[g->count++] = *e;
}

static const table_schema *reg_get(const registry *g, uint64_t table_id)
{
    int i;

    for (i = 0; i < g->count; ++i)
        if (g->entries[i].table_id == table_id) return &g->entries[i];
    return NULL;
}

/* ================================================================== */
/* [5] RowDecoder: decode a row sequence against a TableSchema.         */
/* ================================================================== */

/* Decode one column value and append it to the JSON builder. */
static mb_status decode_value(reader *r, const table_schema *s, int col,
                              int is_null, sb *b)
{
    if (is_null) {
        sb_puts(b, "null");
        return MB_OK;
    }

    switch (s->column_types[col]) {
    case MB_TYPE_LONGLONG: {
        int64_t v = (int64_t)rd_le(r, 8);
        sb_printf(b, "%lld", (long long)v);
        break;
    }
    case MB_TYPE_LONG: {
        int32_t v = (int32_t)(uint32_t)rd_le(r, 4);
        sb_printf(b, "%lld", (long long)v);
        break;
    }
    case MB_TYPE_VARCHAR: {
        char val[512];
        int lb = s->varchar_len_bytes[col];
        uint64_t slen;

        if (lb != 1 && lb != 2) return MB_ERR_UNSUPPORTED;
        slen = rd_le(r, (size_t)lb);
        if (slen > sizeof(val) - 1) return MB_ERR_UNSUPPORTED;
        rd_strn(r, (size_t)slen, val, sizeof(val));
        sb_json_str(b, val);
        break;
    }
    default:
        return MB_ERR_UNSUPPORTED;
    }
    return r->error ? MB_ERR_TRUNCATED : MB_OK;
}

/* Emit the "rows" array. present_bitmap tells which columns carry values;
   UPDATE events carry two bitmaps but the second is implicitly handled by
   reading a second row. */
static mb_status decode_rows(reader *r, const table_schema *s,
                             uint64_t present_bitmap, sb *b)
{
    int nb_size = (s->nullable_count + 7) / 8;
    int rowno = 0;

    sb_puts(b, ",\"rows\":[");

    while (rem(r) > 0 && !r->error) {
        uint64_t null_bitmap;
        int i, first = 1;
        mb_status st;

        if (nb_size > 8) return MB_ERR_UNSUPPORTED;
        null_bitmap = rd_le(r, (size_t)nb_size);
        if (r->error) break;

        if (rowno) sb_putc(b, ',');
        sb_putc(b, '[');
        for (i = 0; i < s->column_count; ++i) {
            if (!(present_bitmap & (1ULL << i))) continue;
            if (!first) sb_putc(b, ',');
            first = 0;
            st = decode_value(r, s, i,
                              (null_bitmap & (1ULL << i)) != 0, b);
            if (st != MB_OK) return st;
            if (r->error) return MB_ERR_TRUNCATED;
        }
        sb_putc(b, ']');
        ++rowno;
    }
    sb_puts(b, "]}");
    return r->error ? MB_ERR_TRUNCATED : MB_OK;
}

/* ================================================================== */
/* [6] EventParser: header, framing, per-event dispatch.                */
/* ================================================================== */

mb_status mb_parse_header(const uint8_t *data, size_t size, mb_event_header *h)
{
    reader r;

    if (!data || !h || size < MB_HEADER_SIZE) return MB_ERR_TRUNCATED;
    rd_init(&r, data, size);
    h->timestamp     = (uint32_t)rd_le(&r, 4);
    h->event_type    = (uint8_t)rd_le(&r, 1);
    h->server_id     = (uint32_t)rd_le(&r, 4);
    h->event_size    = (uint32_t)rd_le(&r, 4);
    h->next_position = (uint32_t)rd_le(&r, 4);
    h->flags         = (uint16_t)rd_le(&r, 2);
    return r.error ? MB_ERR_TRUNCATED : MB_OK;
}

static const char *rows_name(uint8_t t)
{
    if (t == MB_EV_WRITE_ROWS_V2)  return "WRITE_ROWS_EVENT_V2";
    if (t == MB_EV_UPDATE_ROWS_V2) return "UPDATE_ROWS_EVENT_V2";
    if (t == MB_EV_DELETE_ROWS_V2) return "DELETE_ROWS_EVENT_V2";
    return "ROWS_EVENT_V2";
}

/* Parse FORMAT_DESCRIPTION_EVENT and append its JSON. */
static mb_status parse_fde(reader *r, const mb_event_header *h,
                           size_t body_len, const uint8_t *body, sb *b)
{
    uint16_t binlog_version;
    uint8_t version_raw[50];
    char server_version[64];
    uint8_t checksum_alg;
    size_t k = 0;

    if (body_len < 2 + 50 + 1) return MB_ERR_TRUNCATED;
    binlog_version = (uint16_t)rd_le(r, 2);
    rd_raw(r, 50, version_raw);
    while (k < 50 && version_raw[k]) {
        server_version[k] = (char)version_raw[k];
        ++k;
    }
    server_version[k] = '\0';
    checksum_alg = body[body_len - 1];

    sb_printf(b,
        "{\"type\":\"FORMAT_DESCRIPTION_EVENT\",\"timestamp\":%lld,"
        "\"binlog_version\":%lld,\"server_version\":",
        (long long)h->timestamp, (long long)binlog_version);
    sb_json_str(b, server_version);
    sb_printf(b, ",\"checksum_alg\":%lld}", (long long)checksum_alg);
    return r->error ? MB_ERR_TRUNCATED : MB_OK;
}

/* Parse GTID_LOG_EVENT and append its JSON. */
static mb_status parse_gtid(reader *r, const mb_event_header *h, sb *b)
{
    static const char hex[] = "0123456789abcdef";
    uint8_t sid[16];
    char sidhex[33];
    uint64_t gno;
    int i;

    rd_le(r, 1); /* flags */
    rd_raw(r, 16, sid);
    gno = rd_le(r, 8);
    if (r->error) return MB_ERR_TRUNCATED;
    for (i = 0; i < 16; ++i) {
        sidhex[2 * i]     = hex[sid[i] >> 4];
        sidhex[2 * i + 1] = hex[sid[i] & 0x0f];
    }
    sidhex[32] = '\0';

    sb_printf(b,
        "{\"type\":\"GTID_LOG_EVENT\",\"timestamp\":%lld,\"gno\":%lld,\"sid\":",
        (long long)h->timestamp, (long long)gno);
    sb_json_str(b, sidhex);
    sb_puts(b, "}");
    return MB_OK;
}

/* Parse QUERY_EVENT and append its JSON. */
static mb_status parse_query(reader *r, const mb_event_header *h, sb *b)
{
    char db[128], query[2048];
    uint8_t db_len;
    uint16_t sv_len;

    rd_le(r, 4);                       /* thread_id */
    rd_le(r, 4);                       /* exec_time */
    db_len = (uint8_t)rd_le(r, 1);
    rd_le(r, 2);                       /* error_code */
    sv_len = (uint16_t)rd_le(r, 2);
    rd_skip(r, sv_len);                /* status_vars */
    rd_strn(r, db_len, db, sizeof(db));
    rd_le(r, 1);                       /* trailing NUL after db */
    rd_strn(r, rem(r), query, sizeof(query));
    if (r->error) return MB_ERR_TRUNCATED;

    sb_printf(b, "{\"type\":\"QUERY_EVENT\",\"timestamp\":%lld,\"db\":",
              (long long)h->timestamp);
    sb_json_str(b, db);
    sb_printf(b, ",\"query\":");
    sb_json_str(b, query);
    sb_puts(b, "}");
    return MB_OK;
}

/* Parse TABLE_MAP_EVENT, register the schema, and append its JSON. */
static mb_status parse_table_map(reader *r, const mb_event_header *h,
                                 registry *reg, sb *b)
{
    table_schema s;
    char db[128], table[128];
    uint64_t cc, md_len;
    uint8_t db_len, table_len;
    size_t md_start, nb;
    uint64_t null_bitmap;
    int i;

    memset(&s, 0, sizeof(s));
    s.table_id = rd_le(r, 6);
    rd_le(r, 2);                       /* flags */
    db_len = (uint8_t)rd_le(r, 1);
    rd_strn(r, db_len, db, sizeof(db));
    rd_le(r, 1);                       /* NUL */
    table_len = (uint8_t)rd_le(r, 1);
    rd_strn(r, table_len, table, sizeof(table));
    rd_le(r, 1);                       /* NUL */
    cc = rd_lenenc(r);
    if (r->error) return MB_ERR_TRUNCATED;
    if (cc == 0 || cc > MB_MAX_COLS) return MB_ERR_UNSUPPORTED;
    s.column_count = (int)cc;
    for (i = 0; i < s.column_count; ++i)
        s.column_types[i] = (uint8_t)rd_le(r, 1);
    md_len = rd_lenenc(r);
    md_start = r->pos;
    if (r->error || md_len > r->len || md_start > r->len - (size_t)md_len)
        return MB_ERR_TRUNCATED;

    for (i = 0; i < s.column_count; ++i) {
        if (s.column_types[i] == MB_TYPE_VARCHAR) {
            uint16_t maxlen;
            if (r->pos + 2 > md_start + (size_t)md_len)
                return MB_ERR_TRUNCATED;
            maxlen = (uint16_t)rd_le(r, 2);
            s.varchar_len_bytes[i] = (maxlen > 255) ? 2 : 1;
        }
    }
    r->pos = md_start + (size_t)md_len; /* skip any extra metadata */

    nb = ((size_t)s.column_count + 7) / 8;
    if (nb > 8) return MB_ERR_UNSUPPORTED;
    null_bitmap = rd_le(r, nb);
    for (i = 0; i < s.column_count; ++i)
        if (null_bitmap & (1ULL << i)) ++s.nullable_count;
    if (r->error) return MB_ERR_TRUNCATED;

    memcpy(s.db, db, sizeof(db));
    memcpy(s.table, table, sizeof(table));
    reg_put(reg, &s);

    sb_printf(b,
        "{\"type\":\"TABLE_MAP_EVENT\",\"timestamp\":%lld,"
        "\"table_id\":%lld,\"db\":",
        (long long)h->timestamp, (long long)s.table_id);
    sb_json_str(b, s.db);
    sb_printf(b, ",\"table\":");
    sb_json_str(b, s.table);
    sb_printf(b, ",\"column_count\":%lld,\"column_types\":[",
              (long long)s.column_count);
    for (i = 0; i < s.column_count; ++i) {
        if (i) sb_putc(b, ',');
        sb_printf(b, "%lld", (long long)s.column_types[i]);
    }
    sb_puts(b, "]}");
    return MB_OK;
}

/* Parse WRITE/UPDATE/DELETE_ROWS_EVENT_V2 and append its JSON. */
static mb_status parse_rows_v2(reader *r, const mb_event_header *h,
                               const registry *reg, sb *b)
{
    uint64_t table_id, cc, present_bitmap;
    uint16_t extra_len;
    size_t bm_size;
    const table_schema *s;

    table_id = rd_le(r, 6);
    rd_le(r, 2);                       /* flags */
    extra_len = (uint16_t)rd_le(r, 2); /* includes its own 2 bytes */
    if (extra_len < 2) return MB_ERR_UNSUPPORTED;
    rd_skip(r, (size_t)(extra_len - 2));
    cc = rd_lenenc(r);
    if (r->error) return MB_ERR_TRUNCATED;
    if (cc == 0 || cc > MB_MAX_COLS) return MB_ERR_UNSUPPORTED;
    bm_size = (size_t)((cc + 7) / 8);
    if (bm_size > 8) return MB_ERR_UNSUPPORTED;
    present_bitmap = rd_le(r, bm_size);
    if (h->event_type == MB_EV_UPDATE_ROWS_V2)
        rd_le(r, bm_size);             /* before/after bitmap (equal here) */
    if (r->error) return MB_ERR_TRUNCATED;

    s = reg_get(reg, table_id);
    if (!s) return MB_ERR_NO_SCHEMA;

    sb_printf(b, "{\"type\":\"%s\",\"timestamp\":%lld,"
              "\"table_id\":%lld,\"db\":",
              rows_name(h->event_type), (long long)h->timestamp,
              (long long)table_id);
    sb_json_str(b, s->db);
    sb_printf(b, ",\"table\":");
    sb_json_str(b, s->table);
    return decode_rows(r, s, present_bitmap, b);
}

/* Dispatch a single verified event body to its handler. */
static mb_status dispatch_event(const mb_event_header *h, const uint8_t *body,
                                size_t body_len, registry *reg, sb *b)
{
    reader r;
    char q[2048];

    rd_init(&r, body, body_len);

    switch (h->event_type) {
    case MB_EV_FORMAT_DESC:
        return parse_fde(&r, h, body_len, body, b);

    case MB_EV_GTID:
        return parse_gtid(&r, h, b);

    case MB_EV_QUERY:
        return parse_query(&r, h, b);

    case MB_EV_ROWS_QUERY: {
        uint64_t len = rd_lenenc(&r);
        if (r.error) return MB_ERR_TRUNCATED;
        rd_strn(&r, (size_t)len, q, sizeof(q));
        if (r.error) return MB_ERR_TRUNCATED;
        sb_printf(b,
            "{\"type\":\"ROWS_QUERY_LOG_EVENT\",\"timestamp\":%lld,\"query\":",
            (long long)h->timestamp);
        sb_json_str(b, q);
        sb_puts(b, "}");
        return MB_OK;
    }

    case MB_EV_TABLE_MAP:
        return parse_table_map(&r, h, reg, b);

    case MB_EV_WRITE_ROWS_V2:
    case MB_EV_UPDATE_ROWS_V2:
    case MB_EV_DELETE_ROWS_V2:
        return parse_rows_v2(&r, h, reg, b);

    case MB_EV_XID: {
        uint64_t xid = rd_le(&r, 8);
        if (r.error) return MB_ERR_TRUNCATED;
        sb_printf(b, "{\"type\":\"XID_EVENT\",\"timestamp\":%lld,\"xid\":%lld}",
                  (long long)h->timestamp, (long long)xid);
        return MB_OK;
    }

    case MB_EV_ROTATE: {
        uint64_t position = rd_le(&r, 8);
        char next_file[512];
        rd_strn(&r, rem(&r), next_file, sizeof(next_file));
        if (r.error) return MB_ERR_TRUNCATED;
        sb_printf(b,
            "{\"type\":\"ROTATE_EVENT\",\"timestamp\":%lld,"
            "\"position\":%lld,\"next_file\":",
            (long long)h->timestamp, (long long)position);
        sb_json_str(b, next_file);
        sb_puts(b, "}");
        return MB_OK;
    }

    default: /* UNKNOWN -> safe skip, emit a stable one-line record */
        sb_printf(b,
            "{\"type\":\"UNKNOWN\",\"timestamp\":%lld,"
            "\"type_id\":%lld,\"event_size\":%lld}",
            (long long)h->timestamp, (long long)h->event_type,
            (long long)h->event_size);
        return MB_OK;
    }
}

/* ================================================================== */
/* [7] Public API: whole-buffer parser.                                  */
/* ================================================================== */
mb_status mb_parse_buffer(const uint8_t *data, size_t size, FILE *out)
{
    static const uint8_t magic[MB_MAGIC_SIZE] = { 0xFE, 0x62, 0x69, 0x6E };
    registry reg;
    size_t pos;

    if (!data || !out || size < MB_MAGIC_SIZE) return MB_ERR_INVALID;
    if (memcmp(data, magic, MB_MAGIC_SIZE) != 0) return MB_ERR_INVALID;

    reg_init(&reg);
    pos = MB_MAGIC_SIZE;

    while (pos < size) {
        const uint8_t *full, *body;
        size_t es, body_len;
        mb_event_header h;
        char linebuf[MB_LINE_CAP];
        sb b;
        uint32_t stored, calc;
        mb_status st;

        if (size - pos < MB_HEADER_SIZE) return MB_ERR_TRUNCATED;
        if (mb_parse_header(data + pos, MB_HEADER_SIZE, &h) != MB_OK)
            return MB_ERR_TRUNCATED;

        es = h.event_size;
        if (es < MB_HEADER_SIZE + MB_CRC_SIZE || es > MB_MAX_EVENT_SIZE ||
            es > size - pos)
            return MB_ERR_TRUNCATED;

        full = data + pos;
        /* Every event in the controlled subset carries CRC32 (FDE declares
           checksum_alg=1), so it is verified unconditionally here. */
        stored = peek_le32(full + es - MB_CRC_SIZE);
        calc = mb_crc32(full, es - MB_CRC_SIZE);
        if (stored != calc) return MB_ERR_CHECKSUM;

        body = full + MB_HEADER_SIZE;
        body_len = es - MB_HEADER_SIZE - MB_CRC_SIZE;
        sb_init(&b, linebuf, sizeof(linebuf));

        st = dispatch_event(&h, body, body_len, &reg, &b);
        if (st != MB_OK) return st;
        if (b.overflow) return MB_ERR_INVALID;

        fputs(linebuf, out);
        fputc('\n', out);
        pos += es;
    }
    return MB_OK;
}
