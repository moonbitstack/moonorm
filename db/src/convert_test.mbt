// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn[T : @moondb.FromValue] decode(v : @moondb.Value) -> Result[T, String] {
  try @moondb.FromValue::from_value(v) catch {
    e => Err(e.to_string())
  } noraise {
    x => Ok(x)
  }
}

///|
test "each Value case round-trips through its MoonBit type" {
  let cases : Array[@moondb.Value] = [
    @moondb.ToValue::to_value(true),
    @moondb.ToValue::to_value((7 : Int32)),
    @moondb.ToValue::to_value(9000000000L),
    @moondb.ToValue::to_value(9.5),
    @moondb.ToValue::to_value("hero"),
    @moondb.ToValue::to_value(b"\xde\xad"),
  ]
  assert_eq(cases, [
    Bool(true),
    Int(7),
    Int64(9000000000),
    Double(9.5),
    Text("hero"),
    Blob(b"\xde\xad"),
  ])
  assert_eq(decode(Bool(true)), Ok(true))
  assert_eq(decode(Int(7)), Ok((7 : Int32)))
  assert_eq(decode(Int64(9000000000)), Ok(9000000000L))
  assert_eq(decode(Double(9.5)), Ok(9.5))
  assert_eq(decode(Text("hero")), Ok("hero"))
  assert_eq(decode(Blob(b"\xde\xad")), Ok(b"\xde\xad"))
}

///|
test "integers widen and narrow as the typed accessors do" {
  assert_eq(decode(Int(7)), Ok(7L))
  assert_eq(decode(Int(7)), Ok(7.0))
  assert_eq(decode(Int64(5000000000)), Ok(5000000000.0))
  assert_eq(decode(Int64(0x1_0000_0005)), Ok((5 : Int32)))
}

///|
test "a mismatch is a TypeError naming both kinds" {
  let r : Result[Int32, String] = decode(Text("x"))
  assert_eq(r, Err("TypeError: Text, not Int"))
  let r : Result[Bool, String] = decode(Int(1))
  assert_eq(r, Err("TypeError: Int, not Bool"))
  let r : Result[String, String] = decode(Null)
  assert_eq(r, Err("TypeError: Null, not Text"))
}

///|
test "an option binds None as NULL and reads NULL as None" {
  let none : Int32? = None
  assert_eq(@moondb.ToValue::to_value(none), Null)
  assert_eq(@moondb.ToValue::to_value(Some("x")), Text("x"))
  assert_eq(decode(Null), Ok((None : Int32?)))
  assert_eq(decode(Int(3)), Ok(Some((3 : Int32))))
  let r : Result[Int32?, String] = decode(Text("3"))
  assert_eq(r, Err("TypeError: Text, not Int"))
}

///|
test "a Value converts to itself" {
  let v : @moondb.Value = Text("raw")
  assert_eq(@moondb.ToValue::to_value(v), v)
  assert_eq(decode(v), Ok(v))
}

///|
test "Row::read names the column it refused" {
  let row : @moondb.Row = {
    columns: ["id", "age", "name"],
    values: [Int(1), Null, Text("x")],
  }
  let id : Int64 = row.read(0)
  let age : Int32? = row.read(1)
  let name : String = row.read_by("name")
  assert_eq((id, age, name), (1L, None, "x"))
  let refused = try {
    let n : Int32 = row.read(2)
    "\{n}"
  } catch {
    e => e.to_string()
  }
  assert_eq(refused, "TypeError: column 2 is Text, not Int")
}

///|
test "the typed accessors keep their messages" {
  let row : @moondb.Row = { columns: ["a"], values: [Text("x")], }
  let msg = (f : () -> Unit raise @moondb.DbError) => {
    try f() catch {
      e => e.to_string()
    } noraise {
      _ => ""
    }
  }
  assert_eq(
    msg(() => ignore(row.int(0))),
    "TypeError: column 0 is Text, not Int",
  )
  assert_eq(
    msg(() => ignore(row.int64(0))),
    "TypeError: column 0 is Text, not Int64",
  )
  assert_eq(
    msg(() => ignore(row.double(0))),
    "TypeError: column 0 is Text, not Double",
  )
  assert_eq(
    msg(() => ignore(row.bool(0))),
    "TypeError: column 0 is Text, not Bool",
  )
  assert_eq(
    msg(() => ignore(row.blob(0))),
    "TypeError: column 0 is Text, not Blob",
  )
  let row : @moondb.Row = { columns: ["a"], values: [Int(1)], }
  assert_eq(
    msg(() => ignore(row.text(0))),
    "TypeError: column 0 is Int, not Text",
  )
  assert_eq(
    msg(() => ignore(row.int(4))),
    "QueryError: column index 4 out of range (row has 1 columns)",
  )
}

///|
/// A type of the program's own, stored as text.
priv struct Email(String) derive(Eq, Debug)

///|
impl @moondb.ToValue for Email with fn to_value(self) {
  let Email(s) = self
  Text(s)
}

///|
impl @moondb.FromValue for Email with fn from_value(v) {
  match v {
    Text(s) if s.contains("@") => Email(s)
    Text(_) => raise TypeError("text without an @, not Email")
    other => raise TypeError(other.kind() + ", not Email")
  }
}

///|
test "a type of the program's own plugs in through the two traits" {
  assert_eq(@moondb.ToValue::to_value(Email("a@b")), Text("a@b"))
  let row : @moondb.Row = {
    columns: ["mail", "bad", "maybe"],
    values: [Text("a@b"), Text("ab"), Null],
  }
  let mail : Email = row.read(0)
  let maybe : Email? = row.read(2)
  assert_eq((mail, maybe), (Email("a@b"), None))
  let refused = try {
    let e : Email = row.read(1)
    ignore(e)
    ""
  } catch {
    e => e.to_string()
  }
  assert_eq(refused, "TypeError: column 1 is text without an @, not Email")
}
