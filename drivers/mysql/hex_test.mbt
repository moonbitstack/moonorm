// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Bytes as lowercase hexadecimal, for the fixtures the protocol tests carry.
///
/// It lives here rather than coming from `moonbase` because `moon check` does
/// not count a whitebox test's use of an import: a package only the tests reach
/// reads as unused, and eight lines beat a dependency the driver does not have.
fn hex(b : Bytes) -> String {
  let digits = "0123456789abcdef"
  let out = StringBuilder()
  for i in 0..<b.length() {
    let v = b[i].to_int()
    out.write_char(digits[v >> 4].unsafe_to_char())
    out.write_char(digits[v & 0xF].unsafe_to_char())
  }
  out.to_string()
}
