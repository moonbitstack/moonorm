///|
/// A typed streaming cursor: each [`next`](RowStream::next) decodes one row into a
/// record via the model. The record-level counterpart to [`Session::stream`], the
/// streaming form of [`fetch_as`] (SQLAlchemy's `yield_per`).
pub struct RowStream[T] {
  cursor : &@moondb.Cursor
  model : @schema.Model[T]
}

///|
/// The next decoded record, or `None` once the result is exhausted.
pub fn[T] RowStream::next(self : RowStream[T]) -> T? raise @moondb.DbError {
  match self.cursor.next() {
    Some(row) => Some(self.model.map_row(row))
    None => None
  }
}

///|
/// Release the underlying cursor early.
pub fn[T] RowStream::close(self : RowStream[T]) -> Unit {
  self.cursor.close()
}
