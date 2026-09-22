// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Concatenate two byte strings. A small helper the MD5 auth path and message
/// framing lean on; MoonBit's `Bytes` is immutable so this allocates once.
pub fn concat_bytes(a : Bytes, b : Bytes) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(a[:])
  buf.write_bytes(b[:])
  buf.to_bytes()
}

///|
/// A forward cursor over a message payload. The backend framing hands us one
/// `Bytes` per message body (type byte and length already consumed) and every
/// field is read in order, so a single moving offset is all the decoder needs.
/// Reads past the end raise `QueryError` rather than reading garbage — a
/// truncated or malformed backend message surfaces as a protocol error.
priv struct ByteReader {
  data : Bytes
  mut pos : Int
}

///|
fn ByteReader::new(data : Bytes) -> ByteReader {
  { data, pos: 0, }
}

///|
fn ByteReader::u8(self : ByteReader) -> Int raise DbError {
  guard self.pos < self.data.length() else {
    raise QueryError("protocol: read past end of message")
  }
  let v = self.data[self.pos].to_int()
  self.pos += 1
  v
}

///|
/// Read a big-endian signed 16-bit integer (network byte order, as every
/// multi-byte field in the PostgreSQL wire protocol is encoded).
fn ByteReader::i16(self : ByteReader) -> Int raise DbError {
  guard @fixed.read_i16(self.data[:], at=self.pos) is Some(v) else {
    raise QueryError("protocol: read past end of message")
  }
  self.pos += 2
  v
}

///|
/// Read a big-endian signed 32-bit integer.
fn ByteReader::i32(self : ByteReader) -> Int raise DbError {
  guard @fixed.read_i32(self.data[:], at=self.pos) is Some(v) else {
    raise QueryError("protocol: read past end of message")
  }
  self.pos += 4
  v
}

///|
/// Read exactly `n` raw bytes.
fn ByteReader::take(self : ByteReader, n : Int) -> Bytes raise DbError {
  // `n` is a length the server sent, so it can be anything. Comparing `pos + n`
  // overflows for a large one and the guard passes, after which the slice runs
  // backwards and aborts the process rather than raising — subtract instead.
  guard n >= 0 && n <= self.data.length() - self.pos else {
    raise QueryError("protocol: read past end of message")
  }
  let out = self.data[self.pos:self.pos + n].to_owned()
  self.pos += n
  out
}

///|
/// Read a C string: bytes up to (and consuming) the next `NUL`, decoded UTF-8.
fn ByteReader::cstring(self : ByteReader) -> String raise DbError {
  let start = self.pos
  for i = self.pos; i < self.data.length(); i = i + 1 {
    if self.data[i] == 0 {
      let s = utf8_decode(self.data[start:i].to_owned())
      self.pos = i + 1
      return s
    }
  }
  raise QueryError("protocol: unterminated C string")
}

///|
/// Decode UTF-8 bytes to a `String`. PostgreSQL text values, column names, and
/// error fields all arrive UTF-8 (the startup message negotiates
/// `client_encoding`). Decodes the ASCII fast path directly and multi-byte
/// sequences by code point; malformed input yields U+FFFD rather than raising,
/// matching a lenient text codec.
pub fn utf8_decode(data : Bytes) -> String {
  let sb = StringBuilder()
  let n = data.length()
  let mut i = 0
  while i < n {
    let b0 = data[i].to_int()
    if b0 < 0x80 {
      sb.write_char(b0.unsafe_to_char())
      i += 1
    } else if b0 >= 0xc0 && b0 < 0xe0 && i + 1 < n {
      let cp = ((b0 & 0x1f) << 6) | (data[i + 1].to_int() & 0x3f)
      sb.write_char(cp.unsafe_to_char())
      i += 2
    } else if b0 >= 0xe0 && b0 < 0xf0 && i + 2 < n {
      let cp = ((b0 & 0x0f) << 12) |
        ((data[i + 1].to_int() & 0x3f) << 6) |
        (data[i + 2].to_int() & 0x3f)
      sb.write_char(cp.unsafe_to_char())
      i += 3
    } else if b0 >= 0xf0 && i + 3 < n {
      let cp = ((b0 & 0x07) << 18) |
        ((data[i + 1].to_int() & 0x3f) << 12) |
        ((data[i + 2].to_int() & 0x3f) << 6) |
        (data[i + 3].to_int() & 0x3f)
      sb.write_char(cp.unsafe_to_char())
      i += 4
    } else {
      sb.write_char('\u{FFFD}')
      i += 1
    }
  }
  sb.to_string()
}
