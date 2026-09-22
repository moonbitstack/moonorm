// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Render one bound value as a MySQL SQL literal (UTF-8 bytes). Strings are
/// single-quoted with every metacharacter backslash-escaped; blobs use the
/// `x'…'` hex form; NULL/booleans/numbers are their plain literals.
fn render_value(v : @moondb.Value, mode : QuoteMode) -> Bytes {
  match v {
    Null => b"NULL"
    Bool(true) => b"1"
    Bool(false) => b"0"
    Int(i) => string_to_bytes(i.to_string())
    Int64(i) => string_to_bytes(i.to_string())
    Double(d) => string_to_bytes(d.to_string())
    Text(s) => {
      let buf = Buffer()
      buf.write_byte(b'\'')
      escape_into(buf, string_to_bytes(s), mode)
      buf.write_byte(b'\'')
      buf.to_bytes()
    }
    Blob(bytes) => {
      let buf = Buffer()
      buf.write_bytes(b"x'")
      buf.write_bytes(@base16.encode_bytes(bytes))
      buf.write_byte(b'\'')
      buf.to_bytes()
    }
  }
}

///|
/// How the server reads a string literal, which decides how a value has to be
/// escaped. `NO_BACKSLASH_ESCAPES` is part of `ANSI` and of several stock
/// `sql_mode` combinations: there, a backslash is an ordinary character and the
/// only escape is a doubled quote — so a backslash-escaping writer leaves the
/// value's own quote live and the statement is injectable.
pub(all) enum QuoteMode {
  /// The default: backslash escapes are honoured.
  Backslash
  /// `NO_BACKSLASH_ESCAPES` is set: `''` is the only escape.
  DoubleQuote
} derive(Eq)

///|
/// Append `bytes` escaped for `mode`, so the value cannot end the literal it sits
/// in. Escaping happens on UTF-8 bytes and every escaped character is ASCII, so
/// multibyte text passes through untouched.
///
/// Under `DoubleQuote` a backslash is written as itself — doubling it there would
/// corrupt the value — and the control bytes stay raw, which a quoted literal
/// accepts.
fn escape_into(buf : Buffer, bytes : Bytes, mode : QuoteMode) -> Unit {
  if mode is DoubleQuote {
    for i in 0..<bytes.length() {
      if bytes[i].to_int() == 0x27 {
        buf.write_byte(b''')
      }
      buf.write_byte(bytes[i])
    }
    return
  }
  for i in 0..<bytes.length() {
    let c = bytes[i].to_int()
    if c == 0x00 {
      buf.write_byte(b'\\')
      buf.write_byte(b'0')
    } else if c == 0x0A {
      buf.write_byte(b'\\')
      buf.write_byte(b'n')
    } else if c == 0x0D {
      buf.write_byte(b'\\')
      buf.write_byte(b'r')
    } else if c == 0x5C {
      buf.write_byte(b'\\')
      buf.write_byte(b'\\')
    } else if c == 0x27 {
      buf.write_byte(b'\\')
      buf.write_byte(b'\'')
    } else if c == 0x22 {
      buf.write_byte(b'\\')
      buf.write_byte(b'"')
    } else if c == 0x1A {
      buf.write_byte(b'\\')
      buf.write_byte(b'Z')
    } else {
      buf.write_byte(bytes[i])
    }
  }
}

///|
/// Substitute the ordered `params` for the `?` placeholders in `sql`, producing
/// the UTF-8 query bytes a `COM_QUERY` carries.
///
/// The text protocol has no out-of-band parameter binding — that arrives with
/// prepared statements (`COM_STMT_PREPARE`, binary protocol) in a later round —
/// so values are rendered as escaped literals here. The scanner tracks single-,
/// double-, and backtick-quoted spans (honouring backslash escapes) so a literal
/// `?` inside a string or identifier is never mistaken for a placeholder, and it
/// raises when the placeholder and parameter counts disagree.
pub fn bind_params(
  sql : String,
  params : Array[@moondb.Value],
  mode? : QuoteMode = Backslash,
) -> Bytes raise MysqlError {
  let src = string_to_bytes(sql)
  let n = src.length()
  let out = Buffer()
  let mut i = 0
  let mut pi = 0
  let mut in_single = false
  let mut in_double = false
  let mut in_back = false
  while i < n {
    let b = src[i].to_int()
    if in_single {
      out.write_byte(src[i])
      if b == 0x5C && i + 1 < n {
        i += 1
        out.write_byte(src[i])
      } else if b == 0x27 {
        in_single = false
      }
      i += 1
    } else if in_double {
      out.write_byte(src[i])
      if b == 0x5C && i + 1 < n {
        i += 1
        out.write_byte(src[i])
      } else if b == 0x22 {
        in_double = false
      }
      i += 1
    } else if in_back {
      out.write_byte(src[i])
      if b == 0x60 {
        in_back = false
      }
      i += 1
    } else if b == 0x27 {
      in_single = true
      out.write_byte(src[i])
      i += 1
    } else if b == 0x22 {
      in_double = true
      out.write_byte(src[i])
      i += 1
    } else if b == 0x60 {
      in_back = true
      out.write_byte(src[i])
      i += 1
    } else if b == 0x3F {
      if pi >= params.length() {
        raise ProtocolError(
          "too many ? placeholders for the " +
          params.length().to_string() +
          " parameter(s) supplied",
        )
      }
      out.write_bytes(render_value(params[pi], mode)[:])
      pi += 1
      i += 1
    } else {
      out.write_byte(src[i])
      i += 1
    }
  }
  if pi != params.length() {
    raise ProtocolError(
      "parameter count mismatch: bound " +
      pi.to_string() +
      " placeholder(s) but " +
      params.length().to_string() +
      " parameter(s) were supplied",
    )
  }
  out.to_bytes()
}

///|
pub extend QuoteMode with Eq::{not_equal, equal}
