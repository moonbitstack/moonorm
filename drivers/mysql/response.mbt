// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// MySQL column type codes (protocol::ColumnType) — the subset the text-protocol
// decoder maps onto @moondb.Value this round.

///|
const MYSQL_TYPE_TINY : Int = 1

///|
const MYSQL_TYPE_SHORT : Int = 2

///|
const MYSQL_TYPE_LONG : Int = 3

///|
const MYSQL_TYPE_FLOAT : Int = 4

///|
const MYSQL_TYPE_DOUBLE : Int = 5

///|
const MYSQL_TYPE_LONGLONG : Int = 8

///|
const MYSQL_TYPE_INT24 : Int = 9

///|
const MYSQL_TYPE_YEAR : Int = 13

///|
/// The `binary` collation id: a column carrying it is raw bytes, not text.
const COLLATION_BINARY : Int = 63

///|
/// An OK packet: a statement that returned no result set (INSERT/UPDATE/DELETE/DDL)
/// or the terminator of a successful command.
pub(all) struct OkPacket {
  affected_rows : Int64
  last_insert_id : Int64
  status : Int
  warnings : Int
} derive(Eq)

///|
/// One result-set column's definition, reduced to what text decoding needs: the
/// projected name, the MySQL type code, the collation (to tell text from binary),
/// and the column flags.
pub(all) struct ColumnDef {
  name : String
  column_type : Int
  charset : Int
  flags : Int
} derive(Eq)

///|
/// Whether `payload` is an ERR packet (first byte `0xFF`).
pub fn is_err_packet(payload : Bytes) -> Bool {
  payload.length() > 0 && payload[0].to_int() == 0xFF
}

///|
/// Whether `payload` is an EOF packet (first byte `0xFE`, fewer than 9 bytes —
/// which is what tells it apart from a row whose first cell is an 8-byte
/// length-encoded value).
pub fn is_eof_packet(payload : Bytes) -> Bool {
  payload.length() > 0 && payload[0].to_int() == 0xFE && payload.length() < 9
}

///|
/// Whether `payload` is an OK packet (first byte `0x00`, at least 7 bytes).
pub fn is_ok_packet(payload : Bytes) -> Bool {
  payload.length() > 0 && payload[0].to_int() == 0x00 && payload.length() >= 7
}

///|
/// Decode an ERR-packet body positioned right after the `0xFF` marker into
/// `(code, sqlstate, message)`.
fn parse_err_body(r : PacketReader) -> (Int, String, String) raise MysqlError {
  let code = r.uint_le(2).to_int()
  let mut state = ""
  if r.peek() == 0x23 { // '#': the SQLSTATE marker in protocol 41
    r.skip(1)
    state = bytes_to_string(r.bytes(5))
  }
  let msg = bytes_to_string(r.rest())
  (code, state, msg)
}

///|
/// Decode a full ERR packet (including its `0xFF` marker) into the
/// [`MysqlError::ServerError`] it represents.
pub fn parse_err(payload : Bytes) -> MysqlError raise MysqlError {
  let r = PacketReader::new(payload)
  let _ = r.u8()
  let (code, state, msg) = parse_err_body(r)
  ServerError(code, state, msg)
}

///|
/// Decode an OK packet (including its `0x00` marker).
pub fn parse_ok(payload : Bytes) -> OkPacket raise MysqlError {
  let r = PacketReader::new(payload)
  let _ = r.u8()
  let affected = r.lenenc_uint()
  let last_id = r.lenenc_uint()
  let status = r.uint_le(2).to_int()
  let warnings = r.uint_le(2).to_int()
  { affected_rows: affected, last_insert_id: last_id, status, warnings, }
}

///|
fn lenenc_string_or_empty(r : PacketReader) -> String raise MysqlError {
  match r.lenenc_bytes() {
    Some(b) => bytes_to_string(b)
    None => ""
  }
}

///|
/// Decode a column-definition packet (protocol 41). Only the fields that steer
/// text decoding are kept; catalog/schema/table names and the length/decimals
/// fields are read past.
pub fn parse_column_def(payload : Bytes) -> ColumnDef raise MysqlError {
  let r = PacketReader::new(payload)
  let _catalog = r.lenenc_bytes()
  let _schema = r.lenenc_bytes()
  let _table = r.lenenc_bytes()
  let _org_table = r.lenenc_bytes()
  let name = lenenc_string_or_empty(r)
  let _org_name = r.lenenc_bytes()
  let _next_length = r.lenenc_uint() // always 0x0c
  let charset = r.uint_le(2).to_int()
  let _column_length = r.uint_le(4)
  let column_type = r.u8()
  let flags = r.uint_le(2).to_int()
  let _decimals = r.u8()
  { name, column_type, charset, flags, }
}

///|
fn parse_int_cell(raw : Bytes) -> Int raise MysqlError {
  let s = bytes_to_string(raw)
  @string.parse_int(s[:]) catch {
    e =>
      raise ProtocolError(
        "malformed integer cell '" + s + "': " + e.to_string(),
      )
  }
}

///|
fn parse_int64_cell(raw : Bytes) -> Int64 raise MysqlError {
  let s = bytes_to_string(raw)
  @string.parse_int64(s[:]) catch {
    e =>
      raise ProtocolError("malformed bigint cell '" + s + "': " + e.to_string())
  }
}

///|
fn parse_double_cell(raw : Bytes) -> Double raise MysqlError {
  let s = bytes_to_string(raw)
  @string.parse_double(s[:]) catch {
    e =>
      raise ProtocolError("malformed float cell '" + s + "': " + e.to_string())
  }
}

///|
/// Map one text-protocol cell (`None` = the `0xFB` NULL sentinel) onto a
/// [`@moondb.Value`] using the column's declared type. Integers narrow to `Int`
/// except `BIGINT`, which keeps 64 bits; `FLOAT`/`DOUBLE` become `Double`;
/// `binary`-collation strings become `Blob`; everything else (`VARCHAR`, `TEXT`,
/// `DECIMAL`, temporal types as ISO text, JSON) becomes `Text`.
pub fn decode_text_value(
  raw : Bytes?,
  col : ColumnDef,
) -> @moondb.Value raise MysqlError {
  match raw {
    None => @moondb.Null
    Some(bytes) => {
      let t = col.column_type
      if t == MYSQL_TYPE_TINY ||
        t == MYSQL_TYPE_SHORT ||
        t == MYSQL_TYPE_LONG ||
        t == MYSQL_TYPE_INT24 ||
        t == MYSQL_TYPE_YEAR {
        @moondb.Int(parse_int_cell(bytes))
      } else if t == MYSQL_TYPE_LONGLONG {
        @moondb.Int64(parse_int64_cell(bytes))
      } else if t == MYSQL_TYPE_FLOAT || t == MYSQL_TYPE_DOUBLE {
        @moondb.Double(parse_double_cell(bytes))
      } else if col.charset == COLLATION_BINARY {
        @moondb.Blob(bytes)
      } else {
        @moondb.Text(bytes_to_string(bytes))
      }
    }
  }
}

///|
/// Build the materialised rows of a text-protocol result set from its column
/// definitions and the raw row packets. This is the pure heart of `query`: the
/// socket transport collects `columns` and `row_payloads`, and every cell decode
/// happens here, off any backend.
pub fn build_text_rows(
  columns : Array[ColumnDef],
  row_payloads : Array[Bytes],
) -> Array[@moondb.Row] raise MysqlError {
  let names = columns.map(fn(c) { c.name })
  let rows : Array[@moondb.Row] = []
  for payload in row_payloads {
    let r = PacketReader::new(payload)
    let values : Array[@moondb.Value] = []
    for col in columns {
      values.push(decode_text_value(r.lenenc_bytes(), col))
    }
    rows.push(@moondb.Row::{ columns: names, values, })
  }
  rows
}

///|
pub extend ColumnDef with Eq::{not_equal, equal}

///|
pub extend OkPacket with Eq::{not_equal, equal}
