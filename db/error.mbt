// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A database-layer failure. Every fallible operation on the interface raises this
/// one error type, so a query layer catches a single kind. The cases mirror the
/// coarse failure classes both Go's `database/sql` and Python's DB-API 2.0 draw a
/// line around, kept deliberately few so drivers can classify without a taxonomy:
///
/// * `ConnectError` — opening, attaching, or handshaking a connection failed, or
///   the connection dropped mid-flight.
/// * `QueryError`   — the backend rejected a statement: a prepare/step/bind error,
///   a constraint violation, or a protocol error. Carries the backend's message.
/// * `TypeError`    — a [`Row`] typed accessor was asked to read a column as a type
///   it does not hold (e.g. `int` on a `Text`), or a column index/name that does
///   not exist in the row.
/// * `Closed`       — the connection or statement was used after `close`.
///
/// Declared `pub(all)` so out-of-tree drivers (moonpostgres, moonmysql, …) that
/// live in their own packages can *construct and raise* these cases — a plain `pub`
/// suberror would let them catch a `DbError` but not build one.
pub(all) suberror DbError {
  ConnectError(String)
  QueryError(String)
  TypeError(String)
  Closed
}

///|
/// A one-line rendering of the error, e.g. `QueryError: no such table: hero`.
pub fn DbError::to_string(self : DbError) -> String {
  match self {
    ConnectError(m) => "ConnectError: " + m
    QueryError(m) => "QueryError: " + m
    TypeError(m) => "TypeError: " + m
    Closed => "Closed: operation on a closed connection"
  }
}

///|
/// Prints the failure with the detail the driver gave, so a log line says which
/// statement failed rather than only that one did.
pub impl Show for DbError with fn output(self : DbError, logger : &Logger) -> Unit {
  logger.write_string(self.to_string())
}
