// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The async counterpart of [`Cursor`] — a forward-only cursor whose `next` is
/// awaited. A wire driver reads the next row off the socket when it is asked for,
/// which is an I/O round trip and therefore async; the synchronous [`Cursor`]
/// cannot express that, so a networked backend has no way to stream through it.
///
/// The resource discipline is [`Cursor`]'s: MoonBit has no finalizer, so a
/// driver-backed cursor MUST be drained (`next` until `None`) or [`close`d], or the
/// statement leaks and the connection is left mid-result. [`AsyncArrayCursor`] is
/// the materialised fallback, for a driver with no incremental fetch.
///
/// `close` does not raise, mirroring [`Cursor::close`]: abandoning a cursor is
/// best-effort. A driver whose `close` has to do I/O — draining an unread result off
/// the wire — swallows the failure, because a connection whose drain failed is
/// already unusable and the next statement on it will say so.
///
/// `pub(open)` so out-of-tree drivers implement it.
pub(open) trait AsyncCursor {
  /// Advance and return the next row, or `None` at the end of the result.
  async fn next(Self) -> Row? raise DbError
  /// Release the cursor; idempotent, and implied once `next` returns `None`.
  async fn close(Self) -> Unit
}

///|
/// An [`AsyncCursor`] over already-materialised rows — the async twin of
/// [`ArrayCursor`], and what the default [`AsyncDriver::query_stream`] hands back.
/// It preserves the streaming *interface* (rows are pulled one at a time) even
/// though they were all fetched up front.
///
/// It is a separate type from [`ArrayCursor`] rather than a second trait impl on
/// it: one type implementing both `Cursor` and `AsyncCursor` makes every
/// `cursor.next()` on the concrete type ambiguous between the two traits, which
/// would break existing callers.
pub struct AsyncArrayCursor {
  rows : Array[Row]
  mut pos : Int
}

///|
/// A cursor positioned before the first of `rows`.
pub fn AsyncArrayCursor::new(rows : Array[Row]) -> AsyncArrayCursor {
  { rows, pos: 0, }
}

///|
/// Hand back the next row, or `None` once the array is spent. Nothing awaits: the
/// rows are already in memory.
pub impl AsyncCursor for AsyncArrayCursor with fn next(self : AsyncArrayCursor) -> Row? raise DbError {
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
pub impl AsyncCursor for AsyncArrayCursor with fn close(self : AsyncArrayCursor) -> Unit {
  self.pos = self.rows.length()
}

///|
/// Drain an async cursor into an array — the [`drain`] of the async seam, for a
/// caller that wants every row after all, and for asserting a cursor yields exactly
/// what `query` would.
pub async fn drain_async(cursor : &AsyncCursor) -> Array[Row] raise DbError {
  let out = []
  for row = cursor.next(); row is Some(r); row = cursor.next() {
    out.push(r)
  }
  out
}

///|
pub extend AsyncArrayCursor with AsyncCursor::{close, next}
