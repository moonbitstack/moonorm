// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A dependency-free, in-memory reference [`Driver`]. It exists for two reasons:
/// to *prove the interface is implementable* end to end, and to give query layers
/// built on moondb (moonorm and friends) a real test double they can run against
/// with no database and no native backend — it compiles on every target.
///
/// It is a deliberately naive echo store, **not** a SQL engine: it does not parse
/// `sql`. Each `execute` appends one [`Row`] built from the bound `params` (columns
/// named `c0`, `c1`, …) and hands back an [`ExecResult`] with a monotonically
/// increasing `last_insert_id`; each `query` returns every stored row. What it
/// *does* model faithfully is the transaction bracket: `begin` snapshots the store,
/// `rollback` restores it, `commit` keeps the changes — so a test can assert real
/// rollback semantics against it.
pub struct MockDriver {
  mut rows : Array[Row]
  mut next_id : Int64
  savepoints : Array[Int]
  mut closed : Bool
}

///|
/// A fresh, empty mock connection.
pub fn MockDriver::new() -> MockDriver {
  { rows: [], next_id: 0, savepoints: [], closed: false, }
}

///|
/// How many rows the store currently holds. A test-facing helper, not part of the
/// [`Driver`] contract.
pub fn MockDriver::row_count(self : MockDriver) -> Int {
  self.rows.length()
}

///|
/// Whether the connection has been closed.
pub fn MockDriver::is_closed(self : MockDriver) -> Bool {
  self.closed
}

///|
/// Whether a transaction is currently open (at least one un-committed `begin`).
pub fn MockDriver::in_transaction(self : MockDriver) -> Bool {
  self.savepoints.length() > 0
}

///|
/// Record the statement's parameters as a row and report one row affected, with an
/// incrementing last-insert id. The SQL text is ignored on purpose: this driver
/// exists to prove the ORM issued a statement, not to interpret it.
pub impl Driver for MockDriver with fn execute(
  self : MockDriver,
  _sql : String,
  params : Array[Value],
) -> ExecResult raise DbError {
  if self.closed {
    raise Closed
  }
  let columns = []
  for i in 0..<params.length() {
    columns.push("c" + i.to_string())
  }
  self.rows.push({ columns, values: params, })
  self.next_id = self.next_id + 1
  { rows_affected: 1, last_insert_id: self.next_id, }
}

///|
/// Return the recorded rows.
pub impl Driver for MockDriver with fn query(
  self : MockDriver,
  _sql : String,
  _params : Array[Value],
) -> Array[Row] raise DbError {
  if self.closed {
    raise Closed
  }
  self.rows[:].to_owned()
}

///|
/// Open a transaction, or a SAVEPOINT when one is already open, so nesting depth is
/// observable to a test.
pub impl Driver for MockDriver with fn begin(self : MockDriver) -> Unit raise DbError {
  if self.closed {
    raise Closed
  }
  self.savepoints.push(self.rows.length())
}

///|
/// Close the innermost transaction or release the innermost savepoint.
pub impl Driver for MockDriver with fn commit(self : MockDriver) -> Unit raise DbError {
  if self.closed {
    raise Closed
  }
  if self.savepoints.pop() is None {
    raise QueryError("no transaction to commit")
  }
}

///|
/// Undo back to the innermost savepoint, or abandon the transaction.
pub impl Driver for MockDriver with fn rollback(self : MockDriver) -> Unit raise DbError {
  if self.closed {
    raise Closed
  }
  match self.savepoints.pop() {
    Some(n) => self.rows = self.rows[:n].to_owned()
    None => raise QueryError("no transaction to roll back")
  }
}

///|
/// Mark the connection closed; every later call raises `Closed`.
pub impl Driver for MockDriver with fn close(self : MockDriver) -> Unit {
  self.closed = true
}

///|
pub extend MockDriver with Driver::{
  execute,
  begin,
  ping,
  close,
  query_stream,
  commit,
  query,
  rollback,
}
