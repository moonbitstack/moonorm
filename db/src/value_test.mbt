// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "value kind names every variant" {
  assert_eq(@moondb.Value::Null.kind(), "Null")
  assert_eq(@moondb.Value::Bool(true).kind(), "Bool")
  assert_eq(@moondb.Value::Int(1).kind(), "Int")
  assert_eq(@moondb.Value::Int64(1).kind(), "Int64")
  assert_eq(@moondb.Value::Double(1.0).kind(), "Double")
  assert_eq(@moondb.Value::Text("x").kind(), "Text")
  assert_eq(@moondb.Value::Blob(b"\x00").kind(), "Blob")
}

///|
test "value is_null only for Null" {
  assert_eq(@moondb.Value::Null.is_null(), true)
  assert_eq(@moondb.Value::Int(0).is_null(), false)
  assert_eq(@moondb.Value::Text("").is_null(), false)
}

///|
test "value equality is structural" {
  assert_eq(@moondb.Value::Int(7) == @moondb.Value::Int(7), true)
  assert_eq(@moondb.Value::Int(7) == @moondb.Value::Int64(7), false)
  assert_eq(@moondb.Value::Text("a") == @moondb.Value::Text("a"), true)
  assert_eq(@moondb.Value::Blob(b"ab") == @moondb.Value::Blob(b"ab"), true)
  assert_eq(@moondb.Value::Null == @moondb.Value::Null, true)
}

///|
test "value show is legible and hides blob bytes" {
  assert_eq("\{@moondb.Value::Int(42)}", "Int(42)")
  assert_eq("\{@moondb.Value::Text("hi")}", "Text(\"hi\")")
  assert_eq("\{@moondb.Value::Null}", "Null")
  assert_eq("\{@moondb.Value::Blob(b"\x00\x01\x02")}", "Blob(3 bytes)")
}
