// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// What the code `#sql.*` generates calls: reading rows into the shapes a mapper
// function returns, with one refusal for each way a result can be the wrong shape.

///|
/// The column `name` of `row`. A column the query did not select is an error here
/// rather than a default, so a typo in the SQL says what is missing.
pub fn[T : @moondb.FromValue] column(
  row : @moondb.Row,
  name : String,
) -> T raise @moondb.DbError {
  match row.by_name(name) {
    Some(value) => T::from_value(value)
    None => raise QueryError("the query selected no column `\{name}`")
  }
}

///|
/// The first column of `row`, for a function that returns one value.
pub fn[T : @moondb.FromValue] first(
  row : @moondb.Row,
) -> T raise @moondb.DbError {
  T::from_value(row.get(0))
}

///|
/// The row of a query that has to return exactly one.
pub fn one(rows : Array[@moondb.Row]) -> @moondb.Row raise @moondb.DbError {
  match rows {
    [row] => row
    _ => raise QueryError("expected one row, got \{rows.length()}")
  }
}

///|
/// The row of a query that returns at most one.
pub fn optional(
  rows : Array[@moondb.Row],
) -> @moondb.Row? raise @moondb.DbError {
  match rows {
    [] => None
    [row] => Some(row)
    _ => raise QueryError("expected at most one row, got \{rows.length()}")
  }
}
