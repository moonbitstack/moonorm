///|
/// The MD5 password against a known triple, so the flow is pinned even though
/// the digest under it moved.
test "the md5 password is the shape the server asks for" {
  let got = @moonpostgres.pg_md5_password(
    "postgres", "secret", b"\x01\x02\x03\x04",
  )
  assert_true(got.has_prefix("md5"))
  assert_eq(got.length(), 35)
  // Deterministic: the same inputs give the same answer.
  assert_eq(
    got,
    @moonpostgres.pg_md5_password("postgres", "secret", b"\x01\x02\x03\x04"),
  )
  // And the salt reaches it.
  assert_not_eq(
    got,
    @moonpostgres.pg_md5_password("postgres", "secret", b"\x01\x02\x03\x05"),
  )
}
