//! Offline MySQL binlog parser (Phase 1 baseline). Zero external crates.
//!
//! Layered structure (mirrors `c/src/mysqlbinlog.c`):
//!
//!   [1] ByteReader     bounds-checked little-endian primitives
//!   [2] CRC-32         IEEE / zlib checksum
//!   [3] Serializer     canonical JSONL builder (fixed key order, no spaces)
//!   [4] SchemaRegistry table_id -> TableSchema
//!   [5] RowDecoder     decode RowsEventV2 rows using a registered schema
//!   [6] EventParser    frame/verify/dispatch events -> one JSONL line each
//!   [7] Public API     parse_header / crc32 / parse_buffer
//!
//! The public API and the canonical JSONL are a cross-language contract shared
//! by the other nine implementations and `fixtures/expected.jsonl`. Do not
//! change either without a cross-language update.

use std::fmt::Display;

// ==================================================================
// [0] Protocol constants (docs/design.md sections 2-3).
// ==================================================================
const MAGIC: [u8; 4] = [0xFE, 0x62, 0x69, 0x6E];
const HEADER_SIZE: usize = 19;
const CRC_SIZE: usize = 4;
const MAGIC_SIZE: usize = 4;

const MAX_COLS: usize = 64;
const MAX_TABLES: usize = 64;
const MAX_EVENT_SIZE: usize = 256 * 1024 * 1024; // defence against corrupt sizes
const LINE_CAP: usize = 16384;                   // max single JSONL line
const STR_CAP: usize = 2048;                    // max query / next_file string
const VALUE_CAP: usize = 512;                   // max VARCHAR value
const NAME_CAP: usize = 128;                    // max db / table name
const SERVER_VERSION_LEN: usize = 50;

const TYPE_LONG: u8 = 3;
const TYPE_LONGLONG: u8 = 8;
const TYPE_VARCHAR: u8 = 15;

const EV_QUERY: u8 = 2;
const EV_ROTATE: u8 = 4;
const EV_FORMAT_DESC: u8 = 15;
const EV_XID: u8 = 16;
const EV_TABLE_MAP: u8 = 19;
const EV_ROWS_QUERY: u8 = 29;
const EV_WRITE_ROWS_V2: u8 = 30;
const EV_UPDATE_ROWS_V2: u8 = 31;
const EV_DELETE_ROWS_V2: u8 = 32;
const EV_GTID: u8 = 33;

#[derive(Debug, Clone, PartialEq)]
pub enum Error {
    Invalid,
    Truncated,
    Unsupported,
    Checksum,
    NoSchema,
    Io,
}

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Clone, PartialEq)]
pub struct EventHeader {
    pub timestamp: u32,
    pub event_type: u8,
    pub server_id: u32,
    pub event_size: u32,
    pub next_position: u32,
    pub flags: u16,
}

// ==================================================================
// [1] ByteReader: every read is bounds-checked; `error` latches.
// ==================================================================
pub struct Reader<'a> {
    data: &'a [u8],
    len: usize,
    pos: usize,
    error: Option<Error>,
}

impl<'a> Reader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Self { data, len: data.len(), pos: 0, error: None }
    }

    pub fn rem(&self) -> usize {
        self.len.saturating_sub(self.pos)
    }

    pub fn set_pos(&mut self, n: usize) {
        self.pos = n;
    }

    pub fn pos(&self) -> usize { self.pos }

    /// Overflow-safe `pos + n <= len` test.
    fn can(&self, n: usize) -> bool {
        self.error.is_none() && n <= self.len && self.pos <= self.len - n
    }

    fn fail<T>(&mut self, e: Error) -> Result<T> {
        if self.error.is_none() {
            self.error = Some(e.clone());
        }
        Err(e)
    }

    fn err(&self) -> Result<()> {
        match &self.error {
            Some(e) => Err(e.clone()),
            None => Ok(()),
        }
    }

    fn le(&mut self, n: usize) -> Result<u64> {
        if n > 8 || !self.can(n) {
            return self.fail(Error::Truncated);
        }
        let mut v = 0u64;
        for i in 0..n {
            v |= (self.data[self.pos + i] as u64) << (8 * i);
        }
        self.pos += n;
        Ok(v)
    }

    fn raw(&mut self, n: usize) -> Result<&'a [u8]> {
        if !self.can(n) {
            return self.fail(Error::Truncated);
        }
        let d: &'a [u8] = self.data;
        let s = &d[self.pos..self.pos + n];
        self.pos += n;
        Ok(s)
    }

    /// Read exactly n bytes as a bounded string; the reader always advances
    /// by n (alignment preserved) even if truncated to fit cap.
    fn strn(&mut self, n: usize, cap: usize) -> Result<String> {
        if cap == 0 {
            return Ok(String::new());
        }
        if !self.can(n) {
            return self.fail(Error::Truncated);
        }
        let m = n.min(cap - 1);
        let s = String::from_utf8_lossy(&self.data[self.pos..self.pos + m]).into_owned();
        self.pos += n;
        Ok(s)
    }

    fn skip(&mut self, n: usize) -> Result<()> {
        if !self.can(n) {
            return self.fail(Error::Truncated);
        }
        self.pos += n;
        Ok(())
    }

    /// MySQL length-encoded integer. 0xFB (NULL) and 0xFF (reserved) are not
    /// valid lengths where a length is required.
    fn lenenc(&mut self) -> Result<u64> {
        let b = self.le(1)? as u8;
        match b {
            b if b < 0xFB => Ok(b as u64),
            0xFC => self.le(2),
            0xFD => self.le(3),
            0xFE => self.le(8),
            _ => self.fail(Error::Unsupported),
        }
    }

    fn last_byte(&self) -> u8 {
        *self.data.last().unwrap_or(&0)
    }
}

fn peek_le(p: &[u8], n: usize) -> u64 {
    let mut v = 0u64;
    for i in 0..n {
        v |= (p[i] as u64) << (8 * i);
    }
    v
}

// ==================================================================
// [2] CRC-32 (IEEE 802.3 / zlib).
// Vector: crc32(b"123456789") == 0xCBF43926.
// ==================================================================
pub fn crc32(data: &[u8]) -> u32 {
    let mut crc: u32 = 0xFFFF_FFFF;
    for &b in data {
        crc ^= b as u32;
        for _ in 0..8 {
            let mask = 0u32.wrapping_sub(crc & 1);
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    !crc
}

// ==================================================================
// [3] Serializer: bounded canonical JSONL builder.
// ==================================================================
struct Serializer {
    line: String,
    cap: usize,
    overflow: bool,
}

impl Serializer {
    fn new() -> Self {
        Self { line: String::new(), cap: LINE_CAP, overflow: false }
    }

    fn append(&mut self, s: &str) {
        if self.overflow {
            return;
        }
        if self.line.len() + s.len() > self.cap {
            self.overflow = true;
            return;
        }
        self.line.push_str(s);
    }

    fn putc(&mut self, c: char) {
        if !self.overflow && self.line.len() + 1 <= self.cap {
            self.line.push(c);
        } else {
            self.overflow = true;
        }
    }

    fn puts(&mut self, s: &str) { self.append(s); }

    fn uint<T: Display>(&mut self, v: T) { self.append(&format!("{}", v)); }

    /// Minimal JSON escaping: quotes, backslash, control characters.
    fn json_str(&mut self, s: &str) {
        self.putc('"');
        for c in s.chars() {
            match c {
                '"' => self.puts("\\\""),
                '\\' => self.puts("\\\\"),
                '\n' => self.puts("\\n"),
                '\r' => self.puts("\\r"),
                '\t' => self.puts("\\t"),
                c if (c as u32) < 0x20 => self.puts(&format!("\\u{:04x}", c as u32)),
                c => self.putc(c),
            }
        }
        self.putc('"');
    }

    fn finish(self) -> Result<String> {
        if self.overflow {
            return Err(Error::Invalid);
        }
        Ok(self.line)
    }
}

fn bit(v: u64, i: usize) -> bool { v & (1u64 << i) != 0 }

// ==================================================================
// [4] SchemaRegistry: table_id -> TableSchema, per-file lifetime.
// ==================================================================
#[derive(Clone, Default)]
struct Schema {
    table_id: u64,
    db: String,
    table: String,
    column_count: usize,
    column_types: Vec<u8>,
    varchar_len_bytes: Vec<usize>,
    nullable_count: usize,
}

#[derive(Default)]
struct Registry {
    v: Vec<Schema>,
}

impl Registry {
    fn put(&mut self, s: Schema) {
        if let Some(e) = self.v.iter_mut().find(|e| e.table_id == s.table_id) {
            *e = s;
            return;
        }
        if self.v.len() < MAX_TABLES {
            self.v.push(s);
        }
    }

    fn get(&self, id: u64) -> Option<&Schema> {
        self.v.iter().find(|e| e.table_id == id)
    }
}

// ==================================================================
// [5] RowDecoder: decode a row sequence against a Schema.
// ==================================================================
fn decode_value(
    r: &mut Reader<'_>,
    s: &Schema,
    col: usize,
    is_null: bool,
    b: &mut Serializer,
) -> Result<()> {
    if is_null {
        b.puts("null");
        return r.err();
    }
    match s.column_types[col] {
        TYPE_LONGLONG => {
            let v = r.le(8)? as i64;
            b.uint(v);
        }
        TYPE_LONG => {
            let v = r.le(4)? as u32 as i32;
            b.uint(v);
        }
        TYPE_VARCHAR => {
            let lb = s.varchar_len_bytes[col];
            if lb != 1 && lb != 2 {
                return Err(Error::Unsupported);
            }
            let slen = r.le(lb)? as usize;
            if slen > VALUE_CAP - 1 {
                return Err(Error::Unsupported);
            }
            let val = r.strn(slen, VALUE_CAP)?;
            b.json_str(&val);
        }
        _ => return Err(Error::Unsupported),
    }
    r.err()
}

fn decode_rows(
    r: &mut Reader<'_>,
    s: &Schema,
    present: u64,
    b: &mut Serializer,
) -> Result<()> {
    let nb_size = (s.nullable_count + 7) / 8;
    if nb_size > 8 {
        return Err(Error::Unsupported);
    }
    b.puts(",\"rows\":[");
    let mut rowno = 0;
    while r.rem() > 0 && r.error.is_none() {
        let nullbm = r.le(nb_size)?;
        if rowno > 0 {
            b.putc(',');
        }
        b.putc('[');
        let mut first = true;
        for i in 0..s.column_count {
            if !bit(present, i) {
                continue;
            }
            if !first {
                b.putc(',');
            }
            first = false;
            decode_value(r, s, i, bit(nullbm, i), b)?;
            r.err()?;
        }
        b.putc(']');
        rowno += 1;
    }
    b.puts("]}");
    r.err()
}

// ==================================================================
// [6] EventParser: header, framing, per-event dispatch.
// ==================================================================
pub fn parse_header(data: &[u8]) -> Result<EventHeader> {
    if data.len() < HEADER_SIZE {
        return Err(Error::Truncated);
    }
    let mut r = Reader::new(data);
    let h = EventHeader {
        timestamp: r.le(4)? as u32,
        event_type: r.le(1)? as u8,
        server_id: r.le(4)? as u32,
        event_size: r.le(4)? as u32,
        next_position: r.le(4)? as u32,
        flags: r.le(2)? as u16,
    };
    r.err()?;
    Ok(h)
}

fn rows_name(t: u8) -> &'static str {
    match t {
        EV_WRITE_ROWS_V2 => "WRITE_ROWS_EVENT_V2",
        EV_UPDATE_ROWS_V2 => "UPDATE_ROWS_EVENT_V2",
        EV_DELETE_ROWS_V2 => "DELETE_ROWS_EVENT_V2",
        _ => "ROWS_EVENT_V2",
    }
}

fn parse_fde(r: &mut Reader<'_>, h: &EventHeader, b: &mut Serializer) -> Result<()> {
    if r.rem() < 2 + SERVER_VERSION_LEN + 1 {
        return Err(Error::Truncated);
    }
    let bv = r.le(2)? as u16;
    let tmp = r.raw(SERVER_VERSION_LEN)?;
    let alg = r.last_byte();
    let mut sv = String::new();
    for &ch in tmp {
        if ch == 0 { break; }
        sv.push(ch as char);
    }
    b.puts(r#"{"type":"FORMAT_DESCRIPTION_EVENT","timestamp":"#);
    b.uint(h.timestamp);
    b.puts(r#","binlog_version":"#);
    b.uint(bv);
    b.puts(r#","server_version":"#);
    b.json_str(&sv);
    b.puts(r#","checksum_alg":"#);
    b.uint(alg);
    b.putc('}');
    r.err()
}

fn parse_gtid(r: &mut Reader<'_>, h: &EventHeader, b: &mut Serializer) -> Result<()> {
    r.le(1)?; // flags
    let sid = r.raw(16)?;
    let gno = r.le(8)?;
    r.err()?;
    let sh: String = sid.iter().map(|b| format!("{:02x}", b)).collect();
    b.puts(r#"{"type":"GTID_LOG_EVENT","timestamp":"#);
    b.uint(h.timestamp);
    b.puts(r#","gno":"#);
    b.uint(gno);
    b.puts(r#","sid":"#);
    b.json_str(&sh);
    b.putc('}');
    Ok(())
}

fn parse_query(r: &mut Reader<'_>, h: &EventHeader, b: &mut Serializer) -> Result<()> {
    r.le(4)?; // thread_id
    r.le(4)?; // exec_time
    let dbl = r.le(1)? as usize;
    r.le(2)?; // error_code
    let svl = r.le(2)? as usize;
    r.skip(svl)?; // status_vars
    let db = r.strn(dbl, NAME_CAP)?;
    r.le(1)?; // trailing NUL after db
    let query_len = r.rem();
    let query = r.strn(query_len, STR_CAP)?;
    r.err()?;
    b.puts(r#"{"type":"QUERY_EVENT","timestamp":"#);
    b.uint(h.timestamp);
    b.puts(r#","db":"#);
    b.json_str(&db);
    b.puts(r#","query":"#);
    b.json_str(&query);
    b.putc('}');
    Ok(())
}

fn parse_rowsquery(r: &mut Reader<'_>, h: &EventHeader, b: &mut Serializer) -> Result<()> {
    let len = r.lenenc()? as usize;
    let q = r.strn(len, STR_CAP)?;
    r.err()?;
    b.puts(r#"{"type":"ROWS_QUERY_LOG_EVENT","timestamp":"#);
    b.uint(h.timestamp);
    b.puts(r#","query":"#);
    b.json_str(&q);
    b.putc('}');
    Ok(())
}

fn parse_table_map(
    r: &mut Reader<'_>,
    h: &EventHeader,
    reg: &mut Registry,
    b: &mut Serializer,
) -> Result<()> {
    let mut s = Schema::default();
    s.table_id = r.le(6)?;
    r.le(2)?; // flags
    let dbl = r.le(1)? as usize;
    s.db = r.strn(dbl, NAME_CAP)?;
    r.le(1)?; // NUL
    let tl = r.le(1)? as usize;
    s.table = r.strn(tl, NAME_CAP)?;
    r.le(1)?; // NUL
    let cc = r.lenenc()? as usize;
    r.err()?;
    if cc == 0 || cc > MAX_COLS {
        return Err(Error::Unsupported);
    }
    s.column_count = cc;
    for _ in 0..cc {
        s.column_types.push(r.le(1)? as u8);
    }
    let md_len = r.lenenc()? as usize;
    let md_start = r.pos();
    if r.error.is_some() || md_len > r.len || md_start > r.len - md_len {
        return Err(Error::Truncated);
    }
    s.varchar_len_bytes = vec![0; cc];
    for i in 0..cc {
        if s.column_types[i] == TYPE_VARCHAR {
            if r.pos() + 2 > md_start + md_len {
                return Err(Error::Truncated);
            }
            let mx = r.le(2)? as u16;
            s.varchar_len_bytes[i] = if mx > 255 { 2 } else { 1 };
        }
    }
    r.set_pos(md_start + md_len); // skip any extra metadata

    let nb = (cc + 7) / 8;
    if nb > 8 {
        return Err(Error::Unsupported);
    }
    let nullbm = r.le(nb)?;
    for i in 0..cc {
        if bit(nullbm, i) {
            s.nullable_count += 1;
        }
    }
    r.err()?;
    reg.put(s.clone());

    b.puts(r#"{"type":"TABLE_MAP_EVENT","timestamp":"#);
    b.uint(h.timestamp);
    b.puts(r#","table_id":"#);
    b.uint(s.table_id);
    b.puts(r#","db":"#);
    b.json_str(&s.db);
    b.puts(r#","table":"#);
    b.json_str(&s.table);
    b.puts(r#","column_count":"#);
    b.uint(cc);
    b.puts(r#","column_types":["#);
    for i in 0..cc {
        if i > 0 { b.putc(','); }
        b.uint(s.column_types[i]);
    }
    b.puts("]}");
    Ok(())
}

fn parse_rows_v2(
    r: &mut Reader<'_>,
    h: &EventHeader,
    reg: &Registry,
    b: &mut Serializer,
) -> Result<()> {
    let tid = r.le(6)?;
    r.le(2)?; // flags
    let extra_len = r.le(2)? as usize; // includes its own 2 bytes
    if extra_len < 2 {
        return Err(Error::Unsupported);
    }
    r.skip(extra_len - 2)?;
    let cc = r.lenenc()? as usize;
    r.err()?;
    if cc == 0 || cc > MAX_COLS {
        return Err(Error::Unsupported);
    }
    let bm_size = (cc + 7) / 8;
    if bm_size > 8 {
        return Err(Error::Unsupported);
    }
    let present = r.le(bm_size)?;
    if h.event_type == EV_UPDATE_ROWS_V2 {
        r.le(bm_size)?; // before/after bitmap (equal in this subset)
    }
    r.err()?;
    let s = match reg.get(tid).cloned() {
        Some(s) => s,
        None => return Err(Error::NoSchema),
    };

    b.puts(r#"{"type":""#);
    b.puts(rows_name(h.event_type));
    b.puts(r#"","timestamp":"#);
    b.uint(h.timestamp);
    b.puts(r#","table_id":"#);
    b.uint(tid);
    b.puts(r#","db":"#);
    b.json_str(&s.db);
    b.puts(r#","table":"#);
    b.json_str(&s.table);
    decode_rows(r, &s, present, b)
}

fn parse_xid(r: &mut Reader<'_>, h: &EventHeader, b: &mut Serializer) -> Result<()> {
    let xid = r.le(8)?;
    r.err()?;
    b.puts(r#"{"type":"XID_EVENT","timestamp":"#);
    b.uint(h.timestamp);
    b.puts(r#","xid":"#);
    b.uint(xid);
    b.putc('}');
    Ok(())
}

fn parse_rotate(r: &mut Reader<'_>, h: &EventHeader, b: &mut Serializer) -> Result<()> {
    let position = r.le(8)?;
    let nf_len = r.rem();
    let nf = r.strn(nf_len, STR_CAP)?;
    r.err()?;
    b.puts(r#"{"type":"ROTATE_EVENT","timestamp":"#);
    b.uint(h.timestamp);
    b.puts(r#","position":"#);
    b.uint(position);
    b.puts(r#","next_file":"#);
    b.json_str(&nf);
    b.putc('}');
    Ok(())
}

fn parse_unknown(h: &EventHeader, b: &mut Serializer) {
    b.puts(r#"{"type":"UNKNOWN","timestamp":"#);
    b.uint(h.timestamp);
    b.puts(r#","type_id":"#);
    b.uint(h.event_type);
    b.puts(r#","event_size":"#);
    b.uint(h.event_size);
    b.putc('}');
}

/// Dispatch a single verified event body to its named handler.
fn dispatch_event(
    h: &EventHeader,
    body: &[u8],
    reg: &mut Registry,
    b: &mut Serializer,
) -> Result<()> {
    let mut r = Reader::new(body);
    match h.event_type {
        EV_FORMAT_DESC => parse_fde(&mut r, h, b),
        EV_GTID => parse_gtid(&mut r, h, b),
        EV_QUERY => parse_query(&mut r, h, b),
        EV_ROWS_QUERY => parse_rowsquery(&mut r, h, b),
        EV_TABLE_MAP => parse_table_map(&mut r, h, reg, b),
        EV_WRITE_ROWS_V2 | EV_UPDATE_ROWS_V2 | EV_DELETE_ROWS_V2 => {
            parse_rows_v2(&mut r, h, reg, b)
        }
        EV_XID => parse_xid(&mut r, h, b),
        EV_ROTATE => parse_rotate(&mut r, h, b),
        _ => { // UNKNOWN -> safe skip, stable one-line record
            parse_unknown(h, b);
            Ok(())
        }
    }
}

// ==================================================================
// [7] Public API: whole-buffer parser.
// ==================================================================
pub fn parse_buffer(data: &[u8]) -> Result<String> {
    if data.len() < MAGIC_SIZE {
        return Err(Error::Invalid);
    }
    if data[..MAGIC_SIZE] != MAGIC {
        return Err(Error::Invalid);
    }

    let mut reg = Registry::default();
    let mut out = String::new();
    let mut pos = MAGIC_SIZE;
    while pos < data.len() {
        if data.len() - pos < HEADER_SIZE {
            return Err(Error::Truncated);
        }
        let h = parse_header(&data[pos..pos + HEADER_SIZE])?;
        let es = h.event_size as usize;
        if es < HEADER_SIZE + CRC_SIZE || es > MAX_EVENT_SIZE || es > data.len() - pos {
            return Err(Error::Truncated);
        }
        let full = &data[pos..pos + es];
        // Every event in the controlled subset carries CRC32 (FDE declares
        // checksum_alg=1), so it is verified unconditionally here.
        let stored = peek_le(&full[es - CRC_SIZE..], CRC_SIZE) as u32;
        let calc = crc32(&full[..es - CRC_SIZE]);
        if stored != calc {
            return Err(Error::Checksum);
        }
        let body = &full[HEADER_SIZE..es - CRC_SIZE];
        let mut b = Serializer::new();
        dispatch_event(&h, body, &mut reg, &mut b)?;
        out.push_str(&b.finish()?);
        out.push('\n');
        pos += es;
    }
    Ok(out)
}

// ==================================================================
// Unit tests (mirror c/tests/test_parser.c).
// ==================================================================
#[cfg(test)]
mod tests {
    use super::*;

    fn put_le(p: &mut [u8], v: u64, n: usize) {
        for i in 0..n {
            p[i] = (v >> (8 * i)) as u8;
        }
    }

    fn build_event(event_type: u8, crc_override: Option<u32>, body: &[u8]) -> Vec<u8> {
        let es = 19 + body.len() + 4;
        let mut buf = Vec::new();
        buf.extend_from_slice(&MAGIC);
        let mut frame = vec![0u8; 19];
        put_le(&mut frame[0..4], 1, 4);
        frame[4] = event_type;
        put_le(&mut frame[5..9], 1, 4);
        put_le(&mut frame[9..13], es as u64, 4);
        put_le(&mut frame[13..17], (es + 4) as u64, 4);
        put_le(&mut frame[17..19], 0, 2);
        buf.extend_from_slice(&frame);
        buf.extend_from_slice(body);
        let c = crc_override.unwrap_or_else(|| crc32(&buf[MAGIC_SIZE..]));
        buf.extend_from_slice(&c.to_le_bytes());
        buf
    }

    #[test]
    fn crc32_vector() {
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926u32);
    }

    #[test]
    fn header_fields() {
        let mut h = [0u8; 19];
        put_le(&mut h[0..4], 1700000000, 4);
        h[4] = 15;
        put_le(&mut h[5..9], 1, 4);
        put_le(&mut h[9..13], 119, 4);
        put_le(&mut h[13..17], 123, 4);
        put_le(&mut h[17..19], 0, 2);
        let out = parse_header(&h).unwrap();
        assert_eq!(out.timestamp, 1700000000);
        assert_eq!(out.event_type, 15);
        assert_eq!(out.server_id, 1);
        assert_eq!(out.event_size, 119);
        assert_eq!(out.next_position, 123);
        assert_eq!(out.flags, 0);
    }

    #[test]
    fn truncated_header() {
        assert_eq!(parse_header(&[0u8; 10]), Err(Error::Truncated));
        assert_eq!(parse_header(&[]), Err(Error::Truncated));
    }

    #[test]
    fn bad_magic() {
        assert_eq!(parse_buffer(&[0, 0, 0, 0]), Err(Error::Invalid));
    }

    #[test]
    fn empty_buffer() {
        assert_eq!(parse_buffer(&[]), Err(Error::Invalid));
    }

    #[test]
    fn valid_unknown_event() {
        let out = parse_buffer(&build_event(99, None, &[1, 2, 3])).unwrap();
        assert_eq!(
            out,
            "{\"type\":\"UNKNOWN\",\"timestamp\":1,\"type_id\":99,\"event_size\":26}\n"
        );
    }

    #[test]
    fn crc_mismatch() {
        assert_eq!(
            parse_buffer(&build_event(99, Some(0), &[])),
            Err(Error::Checksum)
        );
    }

    #[test]
    fn trailing_partial_header() {
        let mut raw = build_event(99, None, &[]);
        raw.extend_from_slice(&[1, 2, 3]);
        assert_eq!(parse_buffer(&raw), Err(Error::Truncated));
    }

    #[test]
    fn event_size_too_small() {
        let mut raw = build_event(99, None, &[]);
        put_le(&mut raw[4 + 9..4 + 13], 10, 4);
        let c = crc32(&raw[4..raw.len() - 4]);
        let tail = raw.len() - 4;
        raw[tail..].copy_from_slice(&c.to_le_bytes());
        assert_eq!(parse_buffer(&raw), Err(Error::Truncated));
    }

    #[test]
    fn oversized_event_size() {
        let mut raw = build_event(99, None, &[]);
        put_le(&mut raw[4 + 9..4 + 13], 0xFFFF_FFFF, 4);
        let c = crc32(&raw[4..raw.len() - 4]);
        let tail = raw.len() - 4;
        raw[tail..].copy_from_slice(&c.to_le_bytes());
        assert_eq!(parse_buffer(&raw), Err(Error::Truncated));
    }

    #[test]
    fn golden_fixture() {
        let data = include_bytes!("../../fixtures/demo.bin");
        let expected = include_str!("../../fixtures/expected.jsonl");
        assert_eq!(parse_buffer(data).unwrap().as_str(), expected);
    }
}
