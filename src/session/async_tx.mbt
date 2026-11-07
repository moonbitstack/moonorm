// The awaited savepoint handle and the awaited row stream — the two objects a
// session hands out that themselves do I/O. They mirror `Savepoint` and `RowStream`;
// the rollback rules behind them are the same `Core` marks.

///|
/// A nested transaction opened by `AsyncSession::begin_nested`, wrapping one SAVEPOINT
/// whose name and depth the session tracks. Finish it by `release`-ing (keep the work)
/// or `rollback`-ing (discard the work since the savepoint, in the database and in the
/// session's own state). Both are terminal and idempotent.
pub struct AsyncSavepoint {
  sess : AsyncSession
  name : String
  depth : Int32
  mut finished : Bool
}

///|
/// The generated SQL name of this savepoint.
pub fn AsyncSavepoint::name(self : AsyncSavepoint) -> String {
  self.name
}

///|
/// This savepoint's nesting depth (1 for the outermost `begin_nested`).
pub fn AsyncSavepoint::depth(self : AsyncSavepoint) -> Int32 {
  self.depth
}

///|
/// Release this savepoint, keeping the work done since it opened. Terminal and
/// idempotent.
pub async fn AsyncSavepoint::release(
  self : AsyncSavepoint,
) -> Unit raise @moondb.DbError {
  if self.finished {
    return
  }
  self.sess.driver.execute("RELEASE SAVEPOINT " + self.name, []) |> ignore
  self.finished = true
  self.sess.core.close_mark(self.name)
}

///|
/// The same as [`release`], under the name a reader coming from `COMMIT` looks for.
pub async fn AsyncSavepoint::commit(
  self : AsyncSavepoint,
) -> Unit raise @moondb.DbError {
  self.release()
}

///|
/// Roll back and close this savepoint, discarding everything done since it opened —
/// the database rows and the session's queued writes and identity map together — while
/// leaving the enclosing transaction intact. Terminal and idempotent.
pub async fn AsyncSavepoint::rollback(
  self : AsyncSavepoint,
) -> Unit raise @moondb.DbError {
  if self.finished {
    return
  }
  self.sess.driver.execute("ROLLBACK TO SAVEPOINT " + self.name, []) |> ignore
  self.sess.driver.execute("RELEASE SAVEPOINT " + self.name, []) |> ignore
  self.finished = true
  self.sess.core.rewind_to(self.name) |> ignore
  self.sess.core.close_mark(self.name)
}

///|
/// A typed asynchronous streaming cursor: each [`next`](AsyncRowStream::next) awaits
/// one row off the wire and decodes it via the model. The record-level counterpart to
/// [`AsyncSession::stream`].
pub struct AsyncRowStream[T] {
  cursor : &@moondb.AsyncCursor
  model : @schema.Model[T]
}

///|
/// The next decoded record, or `None` once the result is exhausted.
pub async fn[T] AsyncRowStream::next(
  self : AsyncRowStream[T],
) -> T? raise @moondb.DbError {
  match self.cursor.next() {
    Some(row) => Some(self.model.map_row(row))
    None => None
  }
}

///|
/// Release the underlying cursor early.
pub async fn[T] AsyncRowStream::close(self : AsyncRowStream[T]) -> Unit {
  self.cursor.close()
}
