// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "db error renders a one-line message per case" {
  assert_eq(
    (ConnectError("refused") : @moondb.DbError).to_string(),
    "ConnectError: refused",
  )
  assert_eq(
    (QueryError("bad sql") : @moondb.DbError).to_string(),
    "QueryError: bad sql",
  )
  assert_eq(
    (TypeError("not Int") : @moondb.DbError).to_string(),
    "TypeError: not Int",
  )
  assert_eq(
    (Closed : @moondb.DbError).to_string(),
    "Closed: operation on a closed connection",
  )
}

///|
test "db error show matches to_string" {
  let e : @moondb.DbError = QueryError("x")
  assert_eq("\{e}", "QueryError: x")
}
