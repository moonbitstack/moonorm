// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Type-value round-tripping in the wire's *text* format. This round binds and
// decodes everything as text (result format code 0); binary format is a later
// round (README roadmap). PostgreSQL type OIDs are stable, well-known integers.

///|
pub const OID_BOOL : Int = 16

///|
pub const OID_BYTEA : Int = 17

///|
pub const OID_INT8 : Int = 20

///|
pub const OID_INT2 : Int = 21

///|
pub const OID_INT4 : Int = 23

///|
pub const OID_FLOAT4 : Int = 700

///|
pub const OID_FLOAT8 : Int = 701

///|
/// Encode a bound parameter to its text-format bytes, or `None` for SQL `NULL`
/// (which the Bind message sends as a length of `-1`). Binding is out-of-band —
/// the value never touches the SQL string — so this is the injection-safe path.
///
/// * integers / doubles / bools render to their canonical PostgreSQL text
///   literals (`t`/`f` for booleans);
/// * `Text` passes through UTF-8;
/// * `Blob` uses the `bytea` hex format (`\x` + lowercase hex), which the server
///   accepts for a text-format `bytea` parameter.
pub fn encode_param(v : Value) -> Bytes? {
  match v {
    @moondb.Null => None
    @moondb.Bool(b) => Some(@utf8.encode(if b { "t" } else { "f" }))
    @moondb.Int(n) => Some(@utf8.encode(n.to_string()))
    @moondb.Int64(n) => Some(@utf8.encode(n.to_string()))
    @moondb.Double(d) => Some(@utf8.encode(d.to_string()))
    @moondb.Text(s) => Some(@utf8.encode(s))
    @moondb.Blob(b) =>
      Some(@utf8.encode("\\x" + @base16.encode(b[:]).to_lower()))
  }
}

///|
/// Decode a text-format result cell (`raw`, already UTF-8) tagged with its
/// column `oid` into a [`Value`]. `is_null` marks a wire `NULL` (length `-1`),
/// which decodes to `Null` regardless of type. Numeric and boolean OIDs decode
/// to their typed cases; everything else — including `numeric`, dates, and
/// unknown OIDs — rides back as `Text`, exactly the dialect-neutral contract
/// moondb documents (temporal/`numeric` typing is a roadmap item).
pub fn decode_value(oid : Int, is_null : Bool, raw : String) -> Value {
  if is_null {
    return @moondb.Null
  }
  if oid == OID_BOOL {
    @moondb.Bool(raw == "t")
  } else if oid == OID_INT2 || oid == OID_INT4 {
    match parse_int(raw) {
      Some(n) => @moondb.Int(n)
      None => @moondb.Text(raw)
    }
  } else if oid == OID_INT8 {
    match parse_int64(raw) {
      Some(n) => @moondb.Int64(n)
      None => @moondb.Text(raw)
    }
  } else if oid == OID_FLOAT4 || oid == OID_FLOAT8 {
    match parse_double(raw) {
      Some(d) => @moondb.Double(d)
      None => @moondb.Text(raw)
    }
  } else if oid == OID_BYTEA {
    @moondb.Blob(decode_bytea(raw))
  } else {
    @moondb.Text(raw)
  }
}

///|
/// Parse a base-10 `Int`, or `None` if `s` is not a well-formed integer. Used to
/// decode `int2`/`int4` result text; a parse failure falls back to `Text` so a
/// surprising server rendering never silently becomes a wrong number.
pub fn parse_int(s : String) -> Int? {
  match parse_int64(s) {
    Some(v) => Some(v.to_int())
    None => None
  }
}

///|
/// Parse a base-10 `Int64`, or `None` on any non-digit (after an optional sign).
pub fn parse_int64(s : String) -> Int64? {
  let n = s.length()
  if n == 0 {
    return None
  }
  let mut i = 0
  let mut neg = false
  if s[0] == '-' {
    neg = true
    i = 1
  } else if s[0] == '+' {
    i = 1
  }
  if i >= n {
    return None
  }
  let mut acc : Int64 = 0
  while i < n {
    let c = s[i].to_int()
    if c < 48 || c > 57 {
      return None
    }
    acc = acc * 10 + (c - 48).to_int64()
    i += 1
  }
  Some(if neg { -acc } else { acc })
}

///|
/// Parse a floating-point literal from PostgreSQL text (`123.45`, `-1e10`,
/// `Infinity`, `NaN`), or `None` if malformed. Handles sign, fraction, and a
/// base-10 exponent; the special IEEE tokens PostgreSQL emits are recognised.
pub fn parse_double(s : String) -> Double? {
  match s {
    "NaN" => return Some(@double.not_a_number)
    "Infinity" => return Some(@double.infinity)
    "-Infinity" => return Some(@double.neg_infinity)
    _ => ()
  }
  let n = s.length()
  if n == 0 {
    return None
  }
  let mut i = 0
  let mut neg = false
  if s[0] == '-' {
    neg = true
    i = 1
  } else if s[0] == '+' {
    i = 1
  }
  let mut int_part : Double = 0.0
  let mut saw_digit = false
  while i < n && s[i] >= '0' && s[i] <= '9' {
    int_part = int_part * 10.0 + (s[i].to_int() - 48).to_double()
    saw_digit = true
    i += 1
  }
  let mut frac : Double = 0.0
  let mut scale : Double = 1.0
  if i < n && s[i] == '.' {
    i += 1
    while i < n && s[i] >= '0' && s[i] <= '9' {
      frac = frac * 10.0 + (s[i].to_int() - 48).to_double()
      scale = scale * 10.0
      saw_digit = true
      i += 1
    }
  }
  if !saw_digit {
    return None
  }
  let mut mantissa = int_part + frac / scale
  if i < n && (s[i] == 'e' || s[i] == 'E') {
    i += 1
    let mut exp_neg = false
    if i < n && s[i] == '-' {
      exp_neg = true
      i += 1
    } else if i < n && s[i] == '+' {
      i += 1
    }
    if i >= n {
      return None
    }
    let mut exp = 0
    while i < n && s[i] >= '0' && s[i] <= '9' {
      exp = exp * 10 + (s[i].to_int() - 48)
      i += 1
    }
    let mut factor : Double = 1.0
    for _j in 0..<exp {
      factor = factor * 10.0
    }
    mantissa = if exp_neg { mantissa / factor } else { mantissa * factor }
  }
  if i != n {
    return None
  }
  Some(if neg { -mantissa } else { mantissa })
}

///|
/// Decode PostgreSQL `bytea` hex text (`\xDEADBEEF`) back to raw bytes. A value
/// not in hex form (legacy escape format) rides back as its UTF-8 bytes.
pub fn decode_bytea(s : String) -> Bytes {
  if s.has_prefix("\\x") {
    @base16.decode_lossy(s[2:])
  } else {
    @utf8.encode(s)
  }
}
