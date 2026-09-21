// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn sample_row() -> @moondb.Row {
  {
    columns: ["id", "name", "score", "big", "flag", "data", "maybe"],
    values: [
      Int(7),
      Text("hero"),
      Double(9.5),
      Int64(9000000000),
      Bool(true),
      Blob(b"\xde\xad"),
      @moondb.Value::Null,
    ],
  }
}

///|
test "positional accessors read the declared type" {
  let r = sample_row()
  assert_eq(r.width(), 7)
  assert_eq(r.int(0), 7)
  assert_eq(r.text(1), "hero")
  assert_eq(r.double(2), 9.5)
  assert_eq(r.int64(3), 9000000000L)
  assert_eq(r.bool(4), true)
  assert_eq(r.blob(5) == b"\xde\xad", true)
  assert_eq(r.is_null(6), true)
}

///|
test "get returns the raw value and by_name resolves columns" {
  let r = sample_row()
  assert_eq(r.get(0) == Int(7), true)
  assert_eq(r.by_name("name") == Some(Text("hero")), true)
  assert_eq(r.by_name("missing") == None, true)
  assert_eq(r.index_of("score"), 2)
}

///|
test "by-name typed accessors mirror positional ones" {
  let r = sample_row()
  assert_eq(r.int_by("id"), 7)
  assert_eq(r.text_by("name"), "hero")
  assert_eq(r.double_by("score"), 9.5)
  assert_eq(r.int64_by("big"), 9000000000L)
  assert_eq(r.bool_by("flag"), true)
  assert_eq(r.blob_by("data") == b"\xde\xad", true)
  assert_eq(r.is_null_by("maybe"), true)
}

///|
test "integer and double accessors widen and narrow losslessly where defined" {
  let r : @moondb.Row = { columns: ["a"], values: [Int(5)], }
  // Int widens to Int64 and Double.
  assert_eq(r.int64(0), 5L)
  assert_eq(r.double(0), 5.0)
  // Int64 that fits narrows to Int.
  let big : @moondb.Row = { columns: ["a"], values: [Int64(1234)], }
  assert_eq(big.int(0), 1234)
  assert_eq(big.double(0), 1234.0)
}

///|
/// A `TypeError` is raised when the stored value cannot be read as the requested
/// type — including reading a `Null` column without an `is_null` guard.
fn raises_type_error(f : () -> Unit raise @moondb.DbError) -> Bool {
  try {
    f()
    false
  } catch {
    TypeError(_) => true
    _ => false
  }
}

///|
test "wrong-type reads raise TypeError" {
  let r = sample_row()
  assert_eq(raises_type_error(() => r.int(1) |> ignore), true) // Text as Int
  assert_eq(raises_type_error(() => r.text(0) |> ignore), true) // Int as Text
  assert_eq(raises_type_error(() => r.bool(2) |> ignore), true) // Double as Bool
  assert_eq(raises_type_error(() => r.blob(0) |> ignore), true) // Int as Blob
  assert_eq(raises_type_error(() => r.int(6) |> ignore), true) // Null as Int
}

///|
test "out-of-range index raises QueryError, missing name raises QueryError" {
  let r = sample_row()
  let oob = try {
    r.get(99) |> ignore
    false
  } catch {
    QueryError(_) => true
    _ => false
  }
  assert_eq(oob, true)
  let no_col = try {
    r.index_of("nope") |> ignore
    false
  } catch {
    QueryError(_) => true
    _ => false
  }
  assert_eq(no_col, true)
}

///|
test "exec result carries counts and equals structurally" {
  let a : @moondb.ExecResult = { rows_affected: 3, last_insert_id: 42, }
  let b : @moondb.ExecResult = { rows_affected: 3, last_insert_id: 42, }
  assert_eq(a == b, true)
  assert_eq(a.rows_affected, 3L)
  assert_eq(a.last_insert_id, 42L)
}
