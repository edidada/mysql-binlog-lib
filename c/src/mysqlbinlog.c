#include "mysqlbinlog.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* ByteReader: bounds-checked little-endian primitives                  */
/* ------------------------------------------------------------------ */
typedef struct {
    const uint8_t *p;
    size_t len;
    size_t pos;
    int error; /* set on out-of-bounds read */
} reader;

static size_t rem(reader *r) { return r->pos <= r->len ? r->len - r->pos : 0; }

static uint64_t rd_le(reader *r, int n)
{
    uint64_t v = 0;
    int i;
    if (n < 0 || n > 8 || r->pos + (size_t)n > r->len) {
        r->error = 1;
        return 0;
    }
    for (i = 0; i < n; ++i)
        v |= ((uint64_t)r->p[r->pos + (size_t)i]) << (8 * i);
    r->pos += (size_t)n;
    return v;
}

static uint64_t peek_le(const uint8_t *p, int n)
{
    uint64_t v = 0;
    int i;
    for (i = 0; i < n; ++i)
        v |= ((uint64_t)p[i]) << (8 * i);
    return v;
}

static void rd_raw(reader *r, size_t n, uint8_t *dst)
{
    if (r->pos + n > r->len) {
        r->error = 1;
        if (dst) memset(dst, 0, n);
        return;
    }
    if (dst) memcpy(dst, r->p + r->pos, n);
    r->pos += n;
}

/* Read exactly n bytes as a NUL-terminated C string (truncate if cap small,
   but still advance the reader by n to stay aligned). */
static void rd_strn(reader *r, size_t n, char *dst, size_t cap)
{
    size_t m;
    if (r->pos + n > r->len) {
        r->error = 1;
        dst[0] = '\0';
        return;
    }
    m = n < cap - 1 ? n : cap - 1;
    memcpy(dst, r->p + r->pos, m);
    dst[m] = '\0';
    r->pos += n;
}

static void skip(reader *r, size_t n)
{
    if (r->pos + n > r->len) {
        r->error = 1;
        r->pos = r->len;
    } else {
        r->pos += n;
    }
}

static uint64_t rd_lenenc(reader *r, int *is_null)
{
    uint8_t b;
    *is_null = 0;
    b = (uint8_t)rd_le(r, 1);
    if (b < 0xFB) return b;
    if (b == 0xFB) { *is_null = 1; return 0; }
    if (b == 0xFC) return rd_le(r, 2);
    if (b == 0xFD) return rd_le(r, 3);
    if (b == 0xFE) return rd_le(r, 8);
    return 0; /* 0xFF is invalid */
}

/* ------------------------------------------------------------------ */
/* CRC-32 (IEEE / zlib)                                                  */
/* ------------------------------------------------------------------ */
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

/* ------------------------------------------------------------------ */
/* Canonical string builder (no spaces, fixed key order)                 */
/* ------------------------------------------------------------------ */
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

static void sb_json_str(sb *b, const char *s)
{
    sb_putc(b, '"');
    for (; *s; ++s) {
        unsigned char c = (unsigned char)*s;
        switch (c) {
        case '"':  sb_puts(b, "\\\""); break;
        case '\\': sb_puts(b, "\\\\"); break;
        case '\n': sb_puts(b, "\\n"); break;
        case '\r': sb_puts(b, "\\r"); break;
        case '\t': sb_puts(b, "\\t"); break;
        default:
            if (c < 0x20) {
                sb_printf(b, "\\u%04x", (unsigned)c);
            } else {
                sb_putc(b, (char)c);
            }
        }
    }
    sb_putc(b, '"');
}

/* ------------------------------------------------------------------ */
/* SchemaRegistry                                                       */
/* ------------------------------------------------------------------ */
#define MB_MAX_COLS 64
#define MB_MAX_TABLES 64

typedef struct {
    int in_use;
    uint64_t table_id;
    char db[128];
    char table[128];
    int column_count;
    uint8_t column_types[MB_MAX_COLS];
    int varchar_len_bytes[MB_MAX_COLS]; /* 1 or 2, else 0 */
    int nullable_count;
} schema_entry;

typedef struct {
    schema_entry entries[MB_MAX_TABLES];
    int count;
} registry;

static void reg_put(registry *g, const schema_entry *e)
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

static schema_entry *reg_get(registry *g, uint64_t table_id)
{
    int i;
    for (i = 0; i < g->count; ++i)
        if (g->entries[i].table_id == table_id) return &g->entries[i];
    return NULL;
}

/* ------------------------------------------------------------------ */
/* Header                                                               */
/* ------------------------------------------------------------------ */
mb_status mb_parse_header(const uint8_t *data, size_t size, mb_event_header *h)
{
    reader r;
    if (!data || !h || size < 19) return MB_ERR_TRUNCATED;
    r.p = data; r.len = size; r.pos = 0; r.error = 0;
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
    if (t == 30) return "WRITE_ROWS_EVENT_V2";
    if (t == 31) return "UPDATE_ROWS_EVENT_V2";
    if (t == 32) return "DELETE_ROWS_EVENT_V2";
    return "ROWS_EVENT_V2";
}

/* ------------------------------------------------------------------ */
/* Whole-buffer parser                                                   */
/* ------------------------------------------------------------------ */
mb_status mb_parse_buffer(const uint8_t *data, size_t size, FILE *out)
{
    size_t pos;
    registry reg;

    if (!data || !out || size < 4) return MB_ERR_INVALID;
    if (!(data[0] == 0xFE && data[1] == 'b' && data[2] == 'i' && data[3] == 'n'))
        return MB_ERR_INVALID;

    memset(&reg, 0, sizeof(reg));
    pos = 4; /* skip magic */

    while (pos < size) {
        const uint8_t *full;
        const uint8_t *body;
        size_t body_len, es;
        mb_event_header h;
        reader r;
        char linebuf[16384];
        sb b;
        uint32_t stored, calc;
        int is_null;
        mb_status st = MB_OK;

        if (pos + 19 > size) return MB_ERR_TRUNCATED;
        if (mb_parse_header(data + pos, 19, &h) != MB_OK) return MB_ERR_TRUNCATED;
        es = h.event_size;
        if (es < 19 + 4 || pos + es > size) return MB_ERR_TRUNCATED;

        full = data + pos;
        /* Every event in the controlled subset carries CRC32 (FDE declares
           checksum_alg=1), so it is verified unconditionally here. */
        stored = (uint32_t)peek_le(full + es - 4, 4);
        calc = mb_crc32(full, es - 4);
        if (stored != calc) return MB_ERR_CHECKSUM;

        body = full + 19;
        body_len = es - 19 - 4;
        r.p = body; r.len = body_len; r.pos = 0; r.error = 0;
        sb_init(&b, linebuf, sizeof(linebuf));

        switch (h.event_type) {
        case 15: { /* FORMAT_DESCRIPTION_EVENT */
            uint16_t binlog_version = (uint16_t)rd_le(&r, 2);
            uint8_t tmp[50];
            char server_version[64];
            uint8_t checksum_alg;
            size_t k = 0;
            rd_raw(&r, 50, tmp);
            while (k < 50 && tmp[k]) { server_version[k] = (char)tmp[k]; ++k; }
            server_version[k] = '\0';
            checksum_alg = body[body_len - 1];
            sb_printf(&b,
                "{\"type\":\"FORMAT_DESCRIPTION_EVENT\",\"timestamp\":%lld,"
                "\"binlog_version\":%lld,\"server_version\":",
                (long long)h.timestamp, (long long)binlog_version);
            sb_json_str(&b, server_version);
            sb_printf(&b, ",\"checksum_alg\":%lld}", (long long)checksum_alg);
            break;
        }
        case 33: { /* GTID_LOG_EVENT */
            char sidhex[33];
            uint8_t sid[16];
            uint64_t gno;
            int i;
            static const char hex[] = "0123456789abcdef";
            rd_le(&r, 1); /* flags */
            rd_raw(&r, 16, sid);
            gno = rd_le(&r, 8);
            for (i = 0; i < 16; ++i) {
                sidhex[2 * i]     = hex[sid[i] >> 4];
                sidhex[2 * i + 1] = hex[sid[i] & 0x0f];
            }
            sidhex[32] = '\0';
            sb_printf(&b,
                "{\"type\":\"GTID_LOG_EVENT\",\"timestamp\":%lld,\"gno\":%lld,\"sid\":",
                (long long)h.timestamp, (long long)gno);
            sb_json_str(&b, sidhex);
            sb_puts(&b, "}");
            break;
        }
        case 2: { /* QUERY_EVENT */
            char db[128], query[2048];
            uint8_t db_len;
            uint16_t sv_len;
            rd_le(&r, 4); /* thread_id */
            rd_le(&r, 4); /* exec_time */
            db_len = (uint8_t)rd_le(&r, 1);
            rd_le(&r, 2); /* error_code */
            sv_len = (uint16_t)rd_le(&r, 2);
            skip(&r, sv_len); /* status_vars */
            rd_strn(&r, db_len, db, sizeof(db));
            rd_le(&r, 1); /* trailing NUL after db */
            rd_strn(&r, rem(&r), query, sizeof(query));
            sb_printf(&b,
                "{\"type\":\"QUERY_EVENT\",\"timestamp\":%lld,\"db\":",
                (long long)h.timestamp);
            sb_json_str(&b, db);
            sb_printf(&b, ",\"query\":");
            sb_json_str(&b, query);
            sb_puts(&b, "}");
            break;
        }
        case 29: { /* ROWS_QUERY_LOG_EVENT */
            char q[2048];
            uint64_t len = rd_lenenc(&r, &is_null);
            rd_strn(&r, (size_t)len, q, sizeof(q));
            sb_printf(&b,
                "{\"type\":\"ROWS_QUERY_LOG_EVENT\",\"timestamp\":%lld,\"query\":",
                (long long)h.timestamp);
            sb_json_str(&b, q);
            sb_puts(&b, "}");
            break;
        }
        case 19: { /* TABLE_MAP_EVENT */
            schema_entry e;
            char db[128], table[128];
            uint64_t cc, md_len;
            int i, nb, nullable = 0;
            uint64_t nullbm;
            size_t md_start;
            uint8_t db_len, table_len;
            memset(&e, 0, sizeof(e));
            e.in_use = 1;
            e.table_id = rd_le(&r, 6);
            rd_le(&r, 2); /* flags */
            db_len = (uint8_t)rd_le(&r, 1);
            rd_strn(&r, db_len, db, sizeof(db));
            rd_le(&r, 1); /* NUL */
            table_len = (uint8_t)rd_le(&r, 1);
            rd_strn(&r, table_len, table, sizeof(table));
            rd_le(&r, 1); /* NUL */
            cc = rd_lenenc(&r, &is_null);
            e.column_count = (int)cc;
            for (i = 0; i < e.column_count && i < MB_MAX_COLS; ++i)
                e.column_types[i] = (uint8_t)rd_le(&r, 1);
            md_len = rd_lenenc(&r, &is_null);
            md_start = r.pos;
            for (i = 0; i < e.column_count; ++i) {
                if (e.column_types[i] == 15) { /* VARCHAR: 2-byte maxlen */
                    uint16_t maxlen = (uint16_t)rd_le(&r, 2);
                    e.varchar_len_bytes[i] = (maxlen > 255) ? 2 : 1;
                }
            }
            r.pos = md_start + (size_t)md_len; /* skip any extra metadata */
            nb = (e.column_count + 7) / 8;
            nullbm = rd_le(&r, nb);
            for (i = 0; i < e.column_count; ++i)
                if (nullbm & (1ULL << i)) ++nullable;
            e.nullable_count = nullable;
            strcpy(e.db, db);
            strcpy(e.table, table);
            reg_put(&reg, &e);

            sb_printf(&b,
                "{\"type\":\"TABLE_MAP_EVENT\",\"timestamp\":%lld,"
                "\"table_id\":%lld,\"db\":",
                (long long)h.timestamp, (long long)e.table_id);
            sb_json_str(&b, e.db);
            sb_printf(&b, ",\"table\":");
            sb_json_str(&b, e.table);
            sb_printf(&b, ",\"column_count\":%lld,\"column_types\":[",
                (long long)e.column_count);
            for (i = 0; i < e.column_count; ++i) {
                if (i) sb_putc(&b, ',');
                sb_printf(&b, "%lld", (long long)e.column_types[i]);
            }
            sb_puts(&b, "]}");
            break;
        }
        case 30: case 31: case 32: { /* ROWS_EVENT_V2 */
            uint64_t table_id, cc;
            uint16_t extra_len;
            int bm_size, nb_size, rowno = 0;
            uint64_t present1;
            schema_entry *se;

            table_id = rd_le(&r, 6);
            rd_le(&r, 2); /* flags */
            extra_len = (uint16_t)rd_le(&r, 2);
            if (extra_len >= 2) skip(&r, (size_t)(extra_len - 2));
            cc = rd_lenenc(&r, &is_null);
            bm_size = (int)((cc + 7) / 8);
            present1 = rd_le(&r, bm_size);
            if (h.event_type == 31) rd_le(&r, bm_size); /* bitmap2, equal */
            se = reg_get(&reg, table_id);
            if (!se) { st = MB_ERR_NO_SCHEMA; break; }
            nb_size = (se->nullable_count + 7) / 8;

            sb_printf(&b, "{\"type\":\"%s\",\"timestamp\":%lld,"
                "\"table_id\":%lld,\"db\":",
                rows_name(h.event_type), (long long)h.timestamp,
                (long long)table_id);
            sb_json_str(&b, se->db);
            sb_printf(&b, ",\"table\":");
            sb_json_str(&b, se->table);
            sb_printf(&b, ",\"rows\":[");

            while (rem(&r) > 0 && !r.error) {
                uint64_t nullbm = rd_le(&r, nb_size);
                int i, first = 1;
                if (r.error) break;
                if (rowno) sb_putc(&b, ',');
                sb_putc(&b, '[');
                for (i = 0; i < se->column_count; ++i) {
                    uint8_t t;
                    if (!(present1 & (1ULL << i))) continue; /* not present */
                    if (!first) sb_putc(&b, ',');
                    first = 0;
                    if (nullbm & (1ULL << i)) { sb_puts(&b, "null"); continue; }
                    t = se->column_types[i];
                    if (t == 8) { /* LONGLONG */
                        int64_t v = (int64_t)rd_le(&r, 8);
                        sb_printf(&b, "%lld", (long long)v);
                    } else if (t == 3) { /* LONG */
                        int32_t v = (int32_t)(uint32_t)rd_le(&r, 4);
                        sb_printf(&b, "%lld", (long long)v);
                    } else if (t == 15) { /* VARCHAR */
                        int lb = se->varchar_len_bytes[i];
                        char val[512];
                        uint64_t slen;
                        if (lb == 0) lb = 1;
                        slen = rd_le(&r, lb);
                        rd_strn(&r, (size_t)slen, val, sizeof(val));
                        sb_json_str(&b, val);
                    } else {
                        st = MB_ERR_UNSUPPORTED;
                        break;
                    }
                    if (r.error) break;
                }
                sb_putc(&b, ']');
                if (r.error || st != MB_OK) break;
                ++rowno;
            }
            sb_puts(&b, "]}");
            break;
        }
        case 16: { /* XID_EVENT */
            uint64_t xid = rd_le(&r, 8);
            sb_printf(&b, "{\"type\":\"XID_EVENT\",\"timestamp\":%lld,\"xid\":%lld}",
                (long long)h.timestamp, (long long)xid);
            break;
        }
        case 4: { /* ROTATE_EVENT */
            uint64_t position = rd_le(&r, 8);
            char nf[512];
            rd_strn(&r, rem(&r), nf, sizeof(nf));
            sb_printf(&b,
                "{\"type\":\"ROTATE_EVENT\",\"timestamp\":%lld,"
                "\"position\":%lld,\"next_file\":",
                (long long)h.timestamp, (long long)position);
            sb_json_str(&b, nf);
            sb_puts(&b, "}");
            break;
        }
        default: { /* UNKNOWN -> safe skip */
            sb_printf(&b,
                "{\"type\":\"UNKNOWN\",\"timestamp\":%lld,"
                "\"type_id\":%lld,\"event_size\":%lld}",
                (long long)h.timestamp, (long long)h.event_type,
                (long long)h.event_size);
            break;
        }
        }

        if (st != MB_OK) return st;
        if (r.error) return MB_ERR_TRUNCATED;
        if (b.overflow) return MB_ERR_INVALID;
        fputs(linebuf, out);
        fputc('\n', out);
        pos += es;
    }
    return MB_OK;
}
