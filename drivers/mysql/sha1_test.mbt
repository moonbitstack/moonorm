// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Lower-case hex rendering of a byte string — test-local, so the digest and
/// packet tests can assert against the published hex vectors directly.
fn hex(b : Bytes) -> String {
  let digits = "0123456789abcdef"
  let sb = StringBuilder()
  for i in 0..<b.length() {
    let v = b[i].to_int()
    sb.write_char(digits[v >> 4].unsafe_to_char())
    sb.write_char(digits[v & 0xF].unsafe_to_char())
  }
  sb.to_string()
}

///|
test "sha1: NIST/FIPS vectors" {
  assert_eq(
    hex(@moonmysql.sha1(b"")),
    "da39a3ee5e6b4b0d3255bfef95601890afd80709",
  )
  assert_eq(
    hex(@moonmysql.sha1(b"abc")),
    "a9993e364706816aba3e25717850c26c9cd0d89d",
  )
  assert_eq(
    hex(
      @moonmysql.sha1(
        b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
      ),
    ),
    "84983e441c3bd26ebaae4aa1f95129e5e54670f1",
  )
  // The 1,000,000-'a' vector would be slow in CI; a 448-bit boundary case
  // exercises the same multi-block path.
  let millions_of_a = Bytes::make(1000, b'a')
  assert_eq(
    hex(@moonmysql.sha1(millions_of_a)),
    "291e9a6c66994949b57ba5e650361e98fc36b1ba",
  )
}
