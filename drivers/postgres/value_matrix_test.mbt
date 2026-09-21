// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The value-codec completeness matrix, run off any backend (no database needed):
// every @moonpostgres.Value variant through encode_param, every typed OID through decode_value at
// its boundaries, the special float tokens PostgreSQL emits, and bytea in both its
// hex and legacy-escape renderings.

///|
fn enc(v : @moonpostgres.Value) -> String {
  match @moonpostgres.encode_param(v) {
    Some(b) => @moonpostgres.utf8_decode(b)
    None => "<NULL>"
  }
}

///|
test "encode_param renders every non-null variant as its PostgreSQL text literal" {
  assert_eq(enc(@moondb.Null), "<NULL>")
  assert_eq(enc(@moondb.Bool(true)), "t")
  assert_eq(enc(@moondb.Bool(false)), "f")
  assert_eq(enc(@moondb.Int(-2147483648)), "-2147483648")
  assert_eq(enc(@moondb.Int64(9223372036854775807L)), "9223372036854775807")
  assert_eq(
    enc(@moondb.Int64(-9223372036854775807L - 1L)),
    "-9223372036854775808",
  )
  assert_eq(enc(@moondb.Text("")), "")
  assert_eq(enc(@moondb.Text("O'Brien")), "O'Brien")
  assert_eq(enc(@moondb.Blob(b"")), "\\x")
  assert_eq(enc(@moondb.Blob(b"\x00\xff")), "\\x00ff")
}

///|
test "decode_value maps every typed OID, and NULL overrides the type" {
  // int2 / int4 -> Int
  assert_eq(
    @moonpostgres.decode_value(@moonpostgres.OID_INT2, false, "-32768") ==
    @moondb.Int(-32768),
    true,
  )
  assert_eq(
    @moonpostgres.decode_value(@moonpostgres.OID_INT4, false, "0") ==
    @moondb.Int(0),
    true,
  )
  // int8 -> Int64 at the 64-bit boundary
  assert_eq(
    @moonpostgres.decode_value(
      @moonpostgres.OID_INT8,
      false,
      "9223372036854775807",
    ) ==
    @moondb.Int64(9223372036854775807L),
    true,
  )
  // float4 / float8 -> Double
  assert_eq(
    @moonpostgres.decode_value(@moonpostgres.OID_FLOAT4, false, "1.25") ==
    @moondb.Double(1.25),
    true,
  )
  assert_eq(
    @moonpostgres.decode_value(@moonpostgres.OID_FLOAT8, false, "-0.5") ==
    @moondb.Double(-0.5),
    true,
  )
  // bool
  assert_eq(
    @moonpostgres.decode_value(@moonpostgres.OID_BOOL, false, "t") ==
    @moondb.Bool(true),
    true,
  )
  assert_eq(
    @moonpostgres.decode_value(@moonpostgres.OID_BOOL, false, "f") ==
    @moondb.Bool(false),
    true,
  )
  // an unknown OID (e.g. numeric/timestamp) rides back as Text, dialect-neutral
  assert_eq(
    @moonpostgres.decode_value(1700, false, "3.14") == @moondb.Text("3.14"),
    true,
  )
  assert_eq(@moonpostgres.decode_value(25, false, "") == @moondb.Text(""), true)
  // a wire NULL decodes to Null whatever the column type says
  assert_eq(
    @moonpostgres.decode_value(@moonpostgres.OID_INT4, true, "") == @moondb.Null,
    true,
  )
  assert_eq(
    @moonpostgres.decode_value(@moonpostgres.OID_BOOL, true, "") == @moondb.Null,
    true,
  )
}

///|
test "parse_double recognises PostgreSQL's special float tokens" {
  assert_eq(
    @moonpostgres.parse_double("Infinity") == Some(@double.infinity),
    true,
  )
  assert_eq(
    @moonpostgres.parse_double("-Infinity") == Some(@double.neg_infinity),
    true,
  )
  match @moonpostgres.parse_double("NaN") {
    Some(d) => assert_eq(d.is_nan(), true)
    None => fail("NaN did not parse")
  }
  // A float4 column carrying NaN decodes to a NaN Double, not Text.
  match @moonpostgres.decode_value(@moonpostgres.OID_FLOAT8, false, "NaN") {
    @moondb.Double(d) => assert_eq(d.is_nan(), true)
    other => fail("expected Double(NaN), got \{other}")
  }
}

///|
test "decode_bytea handles hex, empty, and the legacy escape rendering" {
  assert_eq(
    @moonpostgres.decode_bytea("\\xdeadbeef") == b"\xde\xad\xbe\xef",
    true,
  )
  assert_eq(@moonpostgres.decode_bytea("\\x").length(), 0)
  // A value not in \x hex form is taken as its UTF-8 bytes (legacy escape output).
  assert_eq(@moonpostgres.decode_bytea("abc") == b"abc", true)
}

///|
test "bytea survives a full encode -> decode round trip" {
  let original = b"\x00\x01\x7f\x80\xfe\xff"
  let hex = enc(@moondb.Blob(original))
  assert_eq(
    @moonpostgres.decode_value(@moonpostgres.OID_BYTEA, false, hex) ==
    @moondb.Blob(original),
    true,
  )
}
