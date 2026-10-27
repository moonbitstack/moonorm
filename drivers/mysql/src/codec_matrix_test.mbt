// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The codec completeness matrix, run on every backend (no server): every Value
// variant rendered into a COM_QUERY through @moonmysql.bind_params (booleans, 64-bit integers,
// doubles, the full string-escape set, and blob hex), the placeholder scanner's
// escape and quoting rules, the parameter-count guards in both directions, and the
// text-row decoder across int / bigint / NULL / binary-blob columns.

///|
fn q(
  sql : String,
  params : Array[@moondb.Value],
) -> String raise @moonmysql.MysqlError {
  @moonmysql.bytes_to_string(@moonmysql.bind_params(sql, params))
}

///|
test "bind_params renders every Value variant as a MySQL literal" {
  assert_eq(q("v ?", [@moondb.Null]), "v NULL")
  assert_eq(q("v ?", [@moondb.Bool(true)]), "v 1")
  assert_eq(q("v ?", [@moondb.Bool(false)]), "v 0")
  assert_eq(q("v ?", [@moondb.Int(-2147483648)]), "v -2147483648")
  assert_eq(
    q("v ?", [@moondb.Int64(9223372036854775807L)]),
    "v 9223372036854775807",
  )
  assert_eq(q("v ?", [@moondb.Double(-2.5)]), "v -2.5")
  assert_eq(q("v ?", [@moondb.Text("plain")]), "v 'plain'")
  // Blob renders as the x'..' hex literal, lowercase, two digits per byte.
  assert_eq(q("v ?", [@moondb.Blob(b"\x00\x1f\xa5\xff")]), "v x'001fa5ff'")
  assert_eq(q("v ?", [@moondb.Blob(b"")]), "v x''")
}

///|
test "bind_params escapes every string metacharacter" {
  // NUL, newline, carriage return, backslash, single quote, double quote, Ctrl-Z.
  assert_eq(q("?", [@moondb.Text("a\u{00}b")]), "'a\\0b'")
  assert_eq(q("?", [@moondb.Text("a\nb")]), "'a\\nb'")
  assert_eq(q("?", [@moondb.Text("a\rb")]), "'a\\rb'")
  assert_eq(q("?", [@moondb.Text("a\\b")]), "'a\\\\b'")
  assert_eq(q("?", [@moondb.Text("a'b")]), "'a\\'b'")
  assert_eq(q("?", [@moondb.Text("a\"b")]), "'a\\\"b'")
  assert_eq(q("?", [@moondb.Text("a\u{1a}b")]), "'a\\Zb'")
  // Multibyte UTF-8 passes through untouched (escaping works on ASCII bytes only).
  assert_eq(q("?", [@moondb.Text("héllo 世界")]), "'héllo 世界'")
}

///|
test "bind_params: a ? inside a quoted span is data, not a placeholder" {
  // Single-quoted string, double-quoted string, and backtick identifier each hide ?.
  assert_eq(
    q("SELECT '?' , \"?\" , `c?l` , ?", [@moondb.Int(1)]),
    "SELECT '?' , \"?\" , `c?l` , 1",
  )
  // An escaped quote inside a single-quoted literal does not end it early.
  assert_eq(
    q("WHERE a = 'it\\'s ? here' AND b = ?", [@moondb.Int(9)]),
    "WHERE a = 'it\\'s ? here' AND b = 9",
  )
}

///|
fn bind_error(sql : String, params : Array[@moondb.Value]) -> Bool {
  try {
    @moonmysql.bind_params(sql, params) |> ignore
    false
  } catch {
    ProtocolError(_) => true
    _ => false
  }
}

///|
test "bind_params rejects a parameter-count mismatch in both directions" {
  // Too few parameters for the placeholders.
  assert_eq(bind_error("a=? b=?", [@moondb.Int(1)]), true)
  // Too many parameters for the placeholders.
  assert_eq(bind_error("a=?", [@moondb.Int(1), @moondb.Int(2)]), true)
  // Exactly right does not raise.
  assert_eq(bind_error("a=? b=?", [@moondb.Int(1), @moondb.Int(2)]), false)
}

///|
test "build_text_rows decodes int, bigint, NULL, and binary blob columns" {
  let cols : Array[@moonmysql.ColumnDef] = [
    { name: "i", column_type: 3, charset: 63, flags: 0, }, // LONG -> Int
    { name: "big", column_type: 8, charset: 63, flags: 0, }, // LONGLONG -> Int64
    { name: "t", column_type: 253, charset: 33, flags: 0, }, // VAR_STRING utf8 -> Text
    { name: "raw", column_type: 252, charset: 63, flags: 0, }, // BLOB binary -> Blob
    { name: "n", column_type: 3, charset: 63, flags: 0, }, // NULL cell
  ]
  let buf = Buffer()
  @moonmysql.put_lenenc_bytes(buf, b"-2147483648")
  @moonmysql.put_lenenc_bytes(buf, b"-9223372036854775808")
  @moonmysql.put_lenenc_bytes(buf, string_to_utf8("héllo"))
  @moonmysql.put_lenenc_bytes(buf, b"\x00\xfe\xff")
  buf.write_byte(b'\xFB') // NULL sentinel for column n
  let rows = @moonmysql.build_text_rows(cols, [buf.to_bytes()])
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].int_by("i"), -2147483648)
  assert_eq(rows[0].int64_by("big"), -9223372036854775807L - 1L)
  assert_eq(rows[0].text_by("t"), "héllo")
  assert_eq(rows[0].blob_by("raw"), b"\x00\xfe\xff")
  assert_eq(rows[0].is_null_by("n"), true)
}

///|
fn string_to_utf8(s : String) -> Bytes {
  @utf8.encode(s)
}
