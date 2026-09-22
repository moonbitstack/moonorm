// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A text-type OID used by the framing tests. The driver decodes any
/// non-numeric OID to `Text`.
const OID_TEXT : Int = 25

///|
/// Read the big-endian Int32 at offset `off` of `b` (test helper).
fn be_i32(b : Bytes, off : Int) -> Int {
  @fixed.read_i32(b[:], at=off).unwrap()
}

///|
/// Build a RowDescription ('T') payload with the given `(name, type OID)`
/// columns, exactly as the backend frames it.
fn make_row_description(cols : Array[(String, Int)]) -> Bytes {
  let w = MsgWriter::new()
  w.i16(cols.length())
  for c in cols {
    w.cstring(c.0)
    w.i32(0) // table OID
    w.i16(0) // column attribute number
    w.i32(c.1) // field type OID
    w.i16(-1) // type size
    w.i32(-1) // type modifier
    w.i16(0) // format code (text)
  }
  w.to_bytes()
}

///|
/// Build a DataRow ('D') payload from already-rendered text cells (`None` ⇒
/// NULL).
fn make_data_row(cells : Array[String?]) -> Bytes {
  let w = MsgWriter::new()
  w.i16(cells.length())
  for cell in cells {
    match cell {
      None => w.i32(-1)
      Some(s) => {
        let b = @utf8.encode(s)
        w.i32(b.length())
        w.raw(b)
      }
    }
  }
  w.to_bytes()
}

///|
test "StartupMessage framing carries version and length" {
  let msg = build_startup("alice", "testdb")
  // no type tag; first Int32 is the self-inclusive length
  assert_eq(be_i32(msg, 0), msg.length())
  // next Int32 is protocol version 3.0 = 196608
  assert_eq(be_i32(msg, 4), 196608)
}

///|
test "simple Query framing: tag 'Q' + length + NUL-terminated sql" {
  let msg = build_query("SELECT 1")
  assert_eq(msg[0].to_int(), 0x51) // 'Q'
  // length counts itself + payload, but not the tag byte
  assert_eq(be_i32(msg, 1), msg.length() - 1)
  // trailing NUL
  assert_eq(msg[msg.length() - 1].to_int(), 0)
}

///|
test "Parse/Bind/Execute/Sync tags are well-formed" {
  assert_eq(build_parse("SELECT $1")[0].to_int(), 0x50) // 'P'
  assert_eq(build_bind([@moondb.Int(1)])[0].to_int(), 0x42) // 'B'
  assert_eq(build_execute()[0].to_int(), 0x45) // 'E'
  let sync = build_sync()
  assert_eq(sync[0].to_int(), 0x53) // 'S'
  assert_eq(be_i32(sync, 1), 4) // empty payload ⇒ length 4
}

///|
test "RowDescription + DataRow decode into a typed Row" {
  let (names, oids) = parse_row_description(
    make_row_description([
      ("id", OID_INT4),
      ("name", OID_TEXT),
      ("score", OID_FLOAT8),
    ]),
  )
  assert_eq(names, ["id", "name", "score"])
  let row = parse_data_row(
    make_data_row([Some("7"), Some("bob"), Some("2.5")]),
    names,
    oids,
  )
  assert_eq(row.int(0), 7)
  assert_eq(row.text(1), "bob")
  assert_eq(row.double(2), 2.5)
  assert_eq(row.int_by("id"), 7)
}

///|
test "DataRow NULL cell decodes to Null" {
  let (names, oids) = parse_row_description(
    make_row_description([("a", OID_INT4), ("b", OID_TEXT)]),
  )
  let row = parse_data_row(make_data_row([None, Some("x")]), names, oids)
  assert_eq(row.is_null(0), true)
  assert_eq(row.text(1), "x")
}
