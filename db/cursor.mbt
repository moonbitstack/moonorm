// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A forward-only cursor over a query's rows — the streaming counterpart to
/// [`Driver::query`]. Where `query` materialises the whole result, a cursor yields
/// one [`Row`] at a time, so a large result set is consumed in bounded memory
/// (SQLAlchemy's `yield_per` / server-side cursors, Go's `sql.Rows`, Python
/// DB-API's `fetchone`).
///
/// `next` advances and returns the next row, or `None` once the result is
/// exhausted; `close` releases the cursor early (a driver holding a server-side
/// cursor or prepared statement frees it here). A driver with real incremental
/// fetch — moonsqlite steps its prepared statement, an async driver reads rows off
/// the wire on demand — returns a live cursor; the default [`Driver::query_stream`]
/// falls back to an [`ArrayCursor`] over a materialised result, which honours the
/// same interface without the memory bound.
///
/// A live cursor holds a resource (a prepared statement, a busy connection). MoonBit
/// has no finalizer to reclaim it, so a driver-backed cursor MUST be fully drained
/// (`next` until `None`) or `close`d — abandoning it leaks the statement or leaves
/// the connection mid-result. The materialised [`ArrayCursor`] holds nothing and is
/// safe to drop.
///
/// `pub(open)` so out-of-tree drivers implement it.
pub(open) trait Cursor {
  /// Advance and return the next row, or `None` at the end of the result.
  fn next(Self) -> Row? raise DbError
  /// Release the cursor; idempotent, and implied once `next` returns `None`.
  fn close(Self) -> Unit
}

///|
/// A [`Cursor`] over an already-materialised `Array[Row]`. The fallback the default
/// [`Driver::query_stream`] hands back for any driver that has not overridden it:
/// it preserves the streaming *interface* (callers pull rows one at a time) even
/// though the rows were fetched up front. The mock driver and the reference query
/// layer test against it.
pub struct ArrayCursor {
  rows : Array[Row]
  mut pos : Int
}

///|
/// A cursor positioned before the first of `rows`.
pub fn ArrayCursor::new(rows : Array[Row]) -> ArrayCursor {
  { rows, pos: 0, }
}

///|
/// Hand back the next row, or `None` once the array is spent.
pub impl Cursor for ArrayCursor with fn next(self : ArrayCursor) -> Row? raise DbError {
  if self.pos < self.rows.length() {
    let row = self.rows[self.pos]
    self.pos += 1
    Some(row)
  } else {
    None
  }
}

///|
/// Nothing to release — the rows are already in memory.
pub impl Cursor for ArrayCursor with fn close(self : ArrayCursor) -> Unit {
  self.pos = self.rows.length()
}

///|
/// Drain a cursor into an array — the inverse of streaming, for callers that do
/// want every row (and for asserting a cursor yields exactly what `query` would).
pub fn drain(cursor : &Cursor) -> Array[Row] raise DbError {
  let out = []
  for row = cursor.next(); row is Some(r); row = cursor.next() {
    out.push(r)
  }
  out
}
