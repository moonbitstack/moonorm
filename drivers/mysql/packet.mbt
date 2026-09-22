// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A cursor over one decoded MySQL packet payload. Every field type the protocol
/// uses — fixed-width little-endian integers, length-encoded integers and strings,
/// NUL-terminated strings, and raw byte runs — is read through this, advancing a
/// position and raising [`MysqlError::ProtocolError`] on any short read. It holds
/// no socket: the transport reads a full payload into `Bytes` first, then parses
/// it here, which is what lets the whole codec be tested off any backend.
pub struct PacketReader {
  data : Bytes
  mut pos : Int
}

///|
/// Wrap a decoded packet payload for reading from the start.
pub fn PacketReader::new(data : Bytes) -> PacketReader {
  { data, pos: 0, }
}

///|
/// Bytes not yet consumed.
pub fn PacketReader::remaining(self : PacketReader) -> Int {
  self.data.length() - self.pos
}

///|
/// Whether the cursor has consumed the whole payload.
pub fn PacketReader::at_end(self : PacketReader) -> Bool {
  self.pos >= self.data.length()
}

///|
/// Peek the next byte without advancing; `-1` at end of payload.
pub fn PacketReader::peek(self : PacketReader) -> Int {
  if self.pos >= self.data.length() {
    -1
  } else {
    self.data[self.pos].to_int()
  }
}

///|
fn PacketReader::need(self : PacketReader, n : Int) -> Unit raise MysqlError {
  if self.pos + n > self.data.length() {
    raise ProtocolError(
      "short packet: need " +
      n.to_string() +
      " byte(s) at offset " +
      self.pos.to_string() +
      ", have " +
      self.data.length().to_string(),
    )
  }
}

///|
/// Read one byte as an `Int` in `0..=255`.
pub fn PacketReader::u8(self : PacketReader) -> Int raise MysqlError {
  self.need(1)
  let v = self.data[self.pos].to_int()
  self.pos += 1
  v
}

///|
/// Read an `n`-byte little-endian unsigned integer.
pub fn PacketReader::uint_le(
  self : PacketReader,
  n : Int,
) -> Int64 raise MysqlError {
  self.need(n)
  guard @fixed.read_uint(self.data[:], at=self.pos, size=n, order=Little)
    is Some(v) else {
    raise ProtocolError("int<" + n.to_string() + "> is not a width")
  }
  self.pos += n
  v.reinterpret_as_int64()
}

///|
/// Read `n` raw bytes.
pub fn PacketReader::bytes(
  self : PacketReader,
  n : Int,
) -> Bytes raise MysqlError {
  self.need(n)
  let s = self.data[self.pos:self.pos + n].to_owned()
  self.pos += n
  s
}

///|
/// Skip `n` bytes.
pub fn PacketReader::skip(
  self : PacketReader,
  n : Int,
) -> Unit raise MysqlError {
  self.need(n)
  self.pos += n
}

///|
/// Read a length-encoded unsigned integer (the `int<lenenc>` type). The `0xFB`
/// NULL sentinel and `0xFF` are rejected here — NULL only has meaning inside a
/// row, which [`lenenc_bytes`] handles.
pub fn PacketReader::lenenc_uint(self : PacketReader) -> Int64 raise MysqlError {
  let (v, used) = @lenenc.decode(self.data[:], at=self.pos) catch {
    @lenenc.Reserved(got~) =>
      raise ProtocolError(
        "invalid length-encoded integer prefix " + got.to_string(),
      )
    @lenenc.Truncated(_) =>
      raise ProtocolError(
        "short packet: an incomplete length-encoded integer at offset " +
        self.pos.to_string(),
      )
  }
  self.pos += used
  v.reinterpret_as_int64()
}

///|
/// Read a length-encoded string (the `string<lenenc>` type), returning `None`
/// for the `0xFB` NULL sentinel that appears in text-protocol rows.
pub fn PacketReader::lenenc_bytes(
  self : PacketReader,
) -> Bytes? raise MysqlError {
  self.need(1)
  if self.data[self.pos].to_int() == 0xFB {
    self.pos += 1
    None
  } else {
    let len = self.lenenc_uint().to_int()
    Some(self.bytes(len))
  }
}

///|
/// Read a NUL-terminated string, consuming the terminator.
pub fn PacketReader::string_nul(self : PacketReader) -> Bytes raise MysqlError {
  let start = self.pos
  while self.pos < self.data.length() && self.data[self.pos].to_int() != 0 {
    self.pos += 1
  }
  if self.pos >= self.data.length() {
    raise ProtocolError("unterminated NUL-string")
  }
  let s = self.data[start:self.pos].to_owned()
  self.pos += 1
  s
}

///|
/// Read everything left in the payload (an `EOF`-terminated string field).
pub fn PacketReader::rest(self : PacketReader) -> Bytes {
  let s = self.data[self.pos:].to_owned()
  self.pos = self.data.length()
  s
}

// --- writers (compose a payload into a Buffer) --------------------------------

///|
/// Append an `n`-byte little-endian unsigned integer.
pub fn put_uint_le(buf : Buffer, v : Int64, n : Int) -> Unit {
  @fixed.write_uint(buf, v.reinterpret_as_uint64(), size=n, order=Little)
}

///|
/// Append a length-encoded unsigned integer.
pub fn put_lenenc_uint(buf : Buffer, v : Int64) -> Unit {
  if v < 0xFBL {
    buf.write_byte(v.to_int().to_byte())
  } else if v < 0x10000L {
    buf.write_byte(b'\xFC')
    put_uint_le(buf, v, 2)
  } else if v < 0x1000000L {
    buf.write_byte(b'\xFD')
    put_uint_le(buf, v, 3)
  } else {
    buf.write_byte(b'\xFE')
    put_uint_le(buf, v, 8)
  }
}

///|
/// Append raw bytes followed by a NUL terminator.
pub fn put_string_nul(buf : Buffer, s : Bytes) -> Unit {
  buf.write_bytes(s[:])
  buf.write_byte(b'\x00')
}

///|
/// Append a length-encoded string (its `lenenc` length prefix, then the bytes).
pub fn put_lenenc_bytes(buf : Buffer, s : Bytes) -> Unit {
  put_lenenc_uint(buf, s.length().to_int64())
  buf.write_bytes(s[:])
}

///|
/// Concatenate two byte strings.
pub fn concat_bytes(a : Bytes, b : Bytes) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(a[:])
  buf.write_bytes(b[:])
  buf.to_bytes()
}
