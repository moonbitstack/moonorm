// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "md5 known vectors (RFC 1321)" {
  assert_eq(
    @moonpostgres.hex_lower(@moonpostgres.md5(b"")),
    "d41d8cd98f00b204e9800998ecf8427e",
  )
  assert_eq(
    @moonpostgres.hex_lower(@moonpostgres.md5(b"abc")),
    "900150983cd24fb0d6963f7d28e17f72",
  )
  assert_eq(
    @moonpostgres.hex_lower(
      @moonpostgres.md5(b"The quick brown fox jumps over the lazy dog"),
    ),
    "9e107d9d372bb6826bd81d3542a419d6",
  )
}

///|
test "md5 spans multiple blocks and exact padding boundary" {
  // 55 bytes: the largest message whose padding + 8-byte length still fit one
  // 64-byte block.
  let s55 = "1234567890123456789012345678901234567890123456789012345"
  assert_eq(s55.length(), 55)
  assert_eq(
    @moonpostgres.hex_lower(@moonpostgres.md5(@utf8.encode(s55))),
    "c9ccf168914a1bcfc3229f1948e67da0",
  )
  // 64 bytes: a full block, forcing a second block that is all padding.
  let s64 = s55 + "123456789"
  assert_eq(s64.length(), 64)
  assert_eq(
    @moonpostgres.hex_lower(@moonpostgres.md5(@utf8.encode(s64))),
    "6cf4948cec9358995476556e2214e4db",
  )
}

///|
test "pg md5 password token" {
  // @moonpostgres.md5("md5" prefix) with user=postgres, password=postgres, salt=01 02 03 04.
  let salt = b"\x01\x02\x03\x04"
  assert_eq(
    @moonpostgres.pg_md5_password("postgres", "postgres", salt),
    "md568be9ed08db75f318087ab337aaea044",
  )
}
