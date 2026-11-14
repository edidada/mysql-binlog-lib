//! Offline MySQL binlog parser (Phase 1 baseline). Zero external crates.
//!
//! Decodes the controlled subset described in `docs/design.md` and emits
//! canonical JSONL lines shared by all four language implementations.

use std::fmt::Display;

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

// ---- ByteReader ----------------------------------------------------------
pub struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }

    pub fn rem(&self) -> usize {
        self.data.len().saturating_sub(self.pos)
    }

    pub fn set_pos(&mut self, n: usize) {
        self.pos = n;
    }

    fn last_byte(&self) -> u8 {
        *self.data.last().unwrap_or(&0)
    }

    fn le(&mut self, n: usize) -> Result<u64> {
        if n > 8 || self.pos + n > self.data.len() {
            return Err(Error::Truncated);
        }
        let mut v = 0u64;
        for i in 0..n {
            v |= (self.data[self.pos + i] as u64) << (8 * i);
        }
        self.pos += n;
        Ok(v)
    }

    fn raw(&mut self, n: usize) -> Result<&'a [u8]> {
        if self.pos + n > self.data.len() {
            return Err(Error::Truncated);
        }
        let d: &'a [u8] = self.data;
        let s = &d[self.pos..self.pos + n];
        self.pos += n;
        Ok(s)
    }

    fn strn(&mut self, n: usize) -> Result<String> {
        let s = self.raw(n)?;
        Ok(String::from_utf8_lossy(s).into_owned())
    }

    fn skip(&mut self, n: usize) -> Result<()> {
        if self.pos + n > self.data.len() {
            return Err(Error::Truncated);
        }
        self.pos += n;
        Ok(())
    }

    fn lenenc(&mut self) -> Result<Option<u64>> {
        let b = self.le(1)? as u8;
        if b < 0xFB {
            return Ok(Some(b as u64));
        }
        match b {
            0xFB => Ok(None),
            0xFC => Ok(Some(self.le(2)?)),
            0xFD => Ok(Some(self.le(3)?)),
            0xFE => Ok(Some(self.le(8)?)),
            _ => Ok(Some(0)),
        }
    }
}

fn peek_le(p: &[u8], n: usize) -> u64 {
    let mut v = 0u64;
    for i in 0..n {
        v |= (p[i] as u64) << (8 * i);
    }
    v
}

// ---- CRC-32 (IEEE / zlib) ------------------------------------------------
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

// ---- Canonical JSON helpers ---------------------------------------------
fn num<T: Display>(v: T) -> String {
    format!("{}", v)
}

fn json_str(s: &str) -> String {
    let mut o = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

// ---- SchemaRegistry ------------------------------------------------------
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
        self.v.push(s);
    }
    fn get(&self, id: u64) -> Option<&Schema> {
        self.v.iter().find(|e| e.table_id == id)
    }
}

fn rows_name(t: u8) -> &'static str {
    match t {
        30 => "WRITE_ROWS_EVENT_V2",
        31 => "UPDATE_ROWS_EVENT_V2",
        32 => "DELETE_ROWS_EVENT_V2",
        _ => "ROWS_EVENT_V2",
    }
}

// ---- Public API ----------------------------------------------------------
pub fn parse_header(data: &[u8]) -> Result<EventHeader> {
    if data.len() < 19 {
        return Err(Error::Truncated);
    }
    let mut r = Reader::new(data);
    Ok(EventHeader {
        timestamp: r.le(4)? as u32,
        event_type: r.le(1)? as u8,
        server_id: r.le(4)? as u32,
        event_size: r.le(4)? as u32,
        next_position: r.le(4)? as u32,
        flags: r.le(2)? as u16,
    })
}

fn emit(h: &EventHeader, r: &mut Reader<'_>, reg: &mut Registry) -> Result<String> {
    let mut line = String::new();
    match h.event_type {
        15 => {
            // FORMAT_DESCRIPTION_EVENT
            let bv = r.le(2)? as u16;
            let tmp = r.raw(50)?;
            let alg = r.last_byte();
            let mut sv = String::new();
            for &b in tmp {
                if b == 0 { break; }
                sv.push(b as char);
            }
            line.push_str(r#"{"type":"FORMAT_DESCRIPTION_EVENT","timestamp":"#);
            line.push_str(&num(h.timestamp));
            line.push_str(r#","binlog_version":"#);
            line.push_str(&num(bv));
            line.push_str(r#","server_version":"#);
            line.push_str(&json_str(&sv));
            line.push_str(r#","checksum_alg":"#);
            line.push_str(&num(alg));
            line.push('}');
        }
        33 => {
            // GTID_LOG_EVENT
            r.le(1)?; // flags
            let sid = r.raw(16)?;
            let gno = r.le(8)?;
            let sh: String = sid.iter().map(|b| format!("{:02x}", b)).collect();
            line.push_str(r#"{"type":"GTID_LOG_EVENT","timestamp":"#);
            line.push_str(&num(h.timestamp));
            line.push_str(r#","gno":"#);
            line.push_str(&num(gno));
            line.push_str(r#","sid":"#);
            line.push_str(&json_str(&sh));
            line.push('}');
        }
        2 => {
            // QUERY_EVENT
            r.le(4)?; // thread_id
            r.le(4)?; // exec_time
            let dbl = r.le(1)? as usize;
            r.le(2)?; // error_code
            let svl = r.le(2)? as usize;
            r.skip(svl)?;
            let db = r.strn(dbl)?;
            r.le(1)?; // trailing NUL
            let qlen = r.rem();
            let query = r.strn(qlen)?;
            line.push_str(r#"{"type":"QUERY_EVENT","timestamp":"#);
            line.push_str(&num(h.timestamp));
            line.push_str(r#","db":"#);
            line.push_str(&json_str(&db));
            line.push_str(r#","query":"#);
            line.push_str(&json_str(&query));
            line.push('}');
        }
        29 => {
            // ROWS_QUERY_LOG_EVENT
            let len = r.lenenc()?.unwrap_or(0) as usize;
            let q = r.strn(len)?;
            line.push_str(r#"{"type":"ROWS_QUERY_LOG_EVENT","timestamp":"#);
            line.push_str(&num(h.timestamp));
            line.push_str(r#","query":"#);
            line.push_str(&json_str(&q));
            line.push('}');
        }
        19 => {
            // TABLE_MAP_EVENT
            let mut s = Schema::default();
            s.table_id = r.le(6)?;
            r.le(2)?; // flags
            let dbl = r.le(1)? as usize;
            s.db = r.strn(dbl)?;
            r.le(1)?; // NUL
            let tl = r.le(1)? as usize;
            s.table = r.strn(tl)?;
            r.le(1)?; // NUL
            let cc = r.lenenc()?.unwrap_or(0) as usize;
            s.column_count = cc;
            for _ in 0..cc {
                s.column_types.push(r.le(1)? as u8);
            }
            let mdlen = r.lenenc()?.unwrap_or(0) as usize;
            let mdstart = r.pos;
            for i in 0..cc {
                if s.column_types[i] == 15 {
                    let mx = r.le(2)? as u16;
                    s.varchar_len_bytes.push(if mx > 255 { 2 } else { 1 });
                } else {
                    s.varchar_len_bytes.push(0);
                }
            }
            r.set_pos(mdstart + mdlen);
            let nb = (cc + 7) / 8;
            let nullbm = r.le(nb)?;
            let mut nullable = 0;
            for i in 0..cc {
                if nullbm & (1u64 << i) != 0 { nullable += 1; }
            }
            s.nullable_count = nullable;
            reg.put(s.clone());

            line.push_str(r#"{"type":"TABLE_MAP_EVENT","timestamp":"#);
            line.push_str(&num(h.timestamp));
            line.push_str(r#","table_id":"#);
            line.push_str(&num(s.table_id));
            line.push_str(r#","db":"#);
            line.push_str(&json_str(&s.db));
            line.push_str(r#","table":"#);
            line.push_str(&json_str(&s.table));
            line.push_str(r#","column_count":"#);
            line.push_str(&num(cc));
            line.push_str(r#","column_types":["#);
            for i in 0..cc {
                if i > 0 { line.push(','); }
                line.push_str(&num(s.column_types[i]));
            }
            line.push_str("]}");
        }
        30 | 31 | 32 => {
            // ROWS_EVENT_V2
            let tid = r.le(6)?;
            r.le(2)?; // flags
            let el = r.le(2)? as usize;
            if el >= 2 { r.skip(el - 2)?; }
            let cc = r.lenenc()?.unwrap_or(0) as usize;
            let bm = (cc + 7) / 8;
            let present1 = r.le(bm)?;
            if h.event_type == 31 { r.le(bm)?; } // bitmap2, equal
            let se = match reg.get(tid).cloned() {
                Some(s) => s,
                None => return Err(Error::NoSchema),
            };
            let nbs = (se.nullable_count + 7) / 8;

            line.push_str(r#"{"type":""#);
            line.push_str(rows_name(h.event_type));
            line.push_str(r#"","timestamp":"#);
            line.push_str(&num(h.timestamp));
            line.push_str(r#","table_id":"#);
            line.push_str(&num(tid));
            line.push_str(r#","db":"#);
            line.push_str(&json_str(&se.db));
            line.push_str(r#","table":"#);
            line.push_str(&json_str(&se.table));
            line.push_str(r#","rows":["#);
            let mut rowno = 0;
            while r.rem() > 0 {
                let nullbm = r.le(nbs)?;
                if rowno > 0 { line.push(','); }
                line.push('[');
                let mut first = true;
                for i in 0..se.column_count {
                    if present1 & (1u64 << i) == 0 { continue; }
                    if !first { line.push(','); }
                    first = false;
                    if nullbm & (1u64 << i) != 0 {
                        line.push_str("null");
                        continue;
                    }
                    let t = se.column_types[i];
                    if t == 8 {
                        let v = r.le(8)? as i64;
                        line.push_str(&num(v));
                    } else if t == 3 {
                        let v = r.le(4)? as u32 as i32;
                        line.push_str(&num(v));
                    } else if t == 15 {
                        let lb = if se.varchar_len_bytes[i] == 0 { 1 } else { se.varchar_len_bytes[i] };
                        let slen = r.le(lb)? as usize;
                        let val = r.strn(slen)?;
                        line.push_str(&json_str(&val));
                    } else {
                        return Err(Error::Unsupported);
                    }
                }
                line.push(']');
                rowno += 1;
            }
            line.push_str("]}");
        }
        16 => {
            // XID_EVENT
            let xid = r.le(8)?;
            line.push_str(r#"{"type":"XID_EVENT","timestamp":"#);
            line.push_str(&num(h.timestamp));
            line.push_str(r#","xid":"#);
            line.push_str(&num(xid));
            line.push('}');
        }
        4 => {
            // ROTATE_EVENT
            let position = r.le(8)?;
            let nflen = r.rem();
            let nf = r.strn(nflen)?;
            line.push_str(r#"{"type":"ROTATE_EVENT","timestamp":"#);
            line.push_str(&num(h.timestamp));
            line.push_str(r#","position":"#);
            line.push_str(&num(position));
            line.push_str(r#","next_file":"#);
            line.push_str(&json_str(&nf));
            line.push('}');
        }
        _ => {
            // UNKNOWN -> safe skip
            line.push_str(r#"{"type":"UNKNOWN","timestamp":"#);
            line.push_str(&num(h.timestamp));
            line.push_str(r#","type_id":"#);
            line.push_str(&num(h.event_type));
            line.push_str(r#","event_size":"#);
            line.push_str(&num(h.event_size));
            line.push('}');
        }
    }
    Ok(line)
}

pub fn parse_buffer(data: &[u8]) -> Result<String> {
    if data.len() < 4 {
        return Err(Error::Invalid);
    }
    if !(data[0] == 0xFE && data[1] == b'b' && data[2] == b'i' && data[3] == b'n') {
        return Err(Error::Invalid);
    }

    let mut reg = Registry::default();
    let mut out = String::new();
    let mut pos = 4usize; // skip magic
    while pos < data.len() {
        if pos + 19 > data.len() {
            return Err(Error::Truncated);
        }
        let h = parse_header(&data[pos..pos + 19])?;
        let es = h.event_size as usize;
        if es < 19 + 4 || pos + es > data.len() {
            return Err(Error::Truncated);
        }
        let full = &data[pos..pos + es];
        // Controlled subset: every event carries CRC32 (FDE declares alg=1).
        let stored = peek_le(&full[es - 4..], 4) as u32;
        let calc = crc32(&full[..es - 4]);
        if stored != calc {
            return Err(Error::Checksum);
        }
        let body = &full[19..es - 4];
        let mut r = Reader::new(body);
        let line = emit(&h, &mut r, &mut reg)?;
        out.push_str(&line);
        out.push('\n');
        pos += es;
    }
    Ok(out)
}

// ---- Unit tests ----------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;

    fn put_le(p: &mut [u8], v: u64, n: usize) {
        for i in 0..n {
            p[i] = (v >> (8 * i)) as u8;
        }
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
        let h = vec![0u8; 10];
        assert_eq!(parse_header(&h), Err(Error::Truncated));
    }

    #[test]
    fn bad_magic() {
        assert_eq!(parse_buffer(&[0, 0, 0, 0]), Err(Error::Invalid));
    }

    #[test]
    fn golden_fixture() {
        let data = include_bytes!("../../fixtures/demo.bin");
        let expected = include_str!("../../fixtures/expected.jsonl");
        assert_eq!(parse_buffer(data).unwrap().as_str(), expected);
    }
}
