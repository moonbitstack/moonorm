// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn row_of() -> @moondb.Row {
  { columns: ["id", "name"], values: [Int(7), Text("ada")], }
}

///|
fn refused(steps : () -> Unit raise) -> String {
  try {
    steps()
    ""
  } catch {
    e => "\{e}"
  }
}

///|
test "a column reads by name, and the first by place" {
  let row = row_of()
  let name : String = @mapper.column(row, "name")
  assert_eq(name, "ada")
  let id : Int64 = @mapper.first(row)
  assert_eq(id, 7L)
}

///|
test "a column the query did not select is named in the error" {
  let got = refused(() => {
    let _ : String = @mapper.column(row_of(), "email")
  })
  assert_true(got.contains("email"))
}

///|
test "one wants exactly one row" {
  let row = row_of()
  assert_eq(@mapper.one([row]), row)
  assert_true(refused(() => ignore(@mapper.one([]))).contains("got 0"))
  assert_true(refused(() => ignore(@mapper.one([row, row]))).contains("got 2"))
}

///|
test "optional takes none or one" {
  let row = row_of()
  assert_eq(@mapper.optional([]), None)
  assert_eq(@mapper.optional([row]), Some(row))
  assert_true(
    refused(() => ignore(@mapper.optional([row, row]))).contains("got 2"),
  )
}
