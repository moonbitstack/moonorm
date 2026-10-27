///|
/// A length the server sent is not trustworthy. `pos + n` overflows for a large one
/// and the guard used to pass, after which the slice ran backwards and aborted the
/// process instead of raising.
test "a huge cell length raises instead of overflowing the bounds check" {
  let r = ByteReader::new(b"hello")
  let _ = r.u8()
  let refused = try {
    let _ = r.take(0x7FFFFFF0)
    false
  } catch {
    _ => true
  }
  assert_eq(refused, true)
  // A legitimate read still works afterwards.
  assert_eq(r.take(2), b"el")
}
