// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "parse_int64 accepts signs and rejects garbage" {
  assert_eq(@moonpostgres.parse_int64("0") == Some(0L), true)
  assert_eq(@moonpostgres.parse_int64("-42") == Some(-42L), true)
  assert_eq(@moonpostgres.parse_int64("+7") == Some(7L), true)
  assert_eq(
    @moonpostgres.parse_int64("9223372036854775807") ==
    Some(9223372036854775807L),
    true,
  )
  assert_eq(@moonpostgres.parse_int64("") == None, true)
  assert_eq(@moonpostgres.parse_int64("12a") == None, true)
  assert_eq(@moonpostgres.parse_int64("-") == None, true)
}

///|
test "parse_double handles fractions and exponents" {
  assert_eq(@moonpostgres.parse_double("3.5") == Some(3.5), true)
  assert_eq(@moonpostgres.parse_double("-0.25") == Some(-0.25), true)
  assert_eq(@moonpostgres.parse_double("1e3") == Some(1000.0), true)
  assert_eq(@moonpostgres.parse_double("2.5e-1") == Some(0.25), true)
  assert_eq(@moonpostgres.parse_double("") == None, true)
  assert_eq(@moonpostgres.parse_double("1.2.3") == None, true)
}

///|
test "decode_value maps type OIDs to typed cases" {
  assert_eq(
    @moonpostgres.decode_value(@moonpostgres.OID_INT4, false, "123") ==
    @moondb.Int(123),
    true,
  )
  assert_eq(
    @moonpostgres.decode_value(@moonpostgres.OID_INT8, false, "10000000000") ==
    @moondb.Int64(10000000000L),
    true,
  )
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
  assert_eq(
    @moonpostgres.decode_value(@moonpostgres.OID_FLOAT8, false, "1.5") ==
    @moondb.Double(1.5),
    true,
  )
  assert_eq(
    @moonpostgres.decode_value(25, false, "hello") == @moondb.Text("hello"),
    true,
  )
  // NULL wins over any type
  assert_eq(
    @moonpostgres.decode_value(@moonpostgres.OID_INT4, true, "") == @moondb.Null,
    true,
  )
}

///|
test "decode_value bytea hex round-trips through encode_param" {
  let original = b"\x00\xde\xad\xbe\xef\x7f"
  let decoded = @moonpostgres.decode_value(
    @moonpostgres.OID_BYTEA,
    false,
    "\\x00deadbeef7f",
  )
  assert_eq(decoded == @moondb.Blob(original), true)
  // encode_param of that blob is the same \x hex text a bind would send
  match @moonpostgres.encode_param(@moondb.Blob(original)) {
    Some(bytes) =>
      assert_eq(@moonpostgres.utf8_decode(bytes), "\\x00deadbeef7f")
    None => fail("blob encoded as NULL")
  }
}

///|
test "encode_param renders bound values as text, NULL as None" {
  assert_eq(@moonpostgres.encode_param(@moondb.Null) is None, true)
  match @moonpostgres.encode_param(@moondb.Int(42)) {
    Some(b) => assert_eq(@moonpostgres.utf8_decode(b), "42")
    None => fail("Int became NULL")
  }
  match @moonpostgres.encode_param(@moondb.Bool(true)) {
    Some(b) => assert_eq(@moonpostgres.utf8_decode(b), "t")
    None => fail("Bool became NULL")
  }
  match @moonpostgres.encode_param(@moondb.Text("O'Brien")) {
    Some(b) => assert_eq(@moonpostgres.utf8_decode(b), "O'Brien")
    None => fail("Text became NULL")
  }
}
