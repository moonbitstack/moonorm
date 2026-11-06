///|
/// A driver that records what it was handed — statement, bound values, transaction
/// calls — so an event test can assert both that a hook fired and what the flush did
/// with what the hook left behind.
struct HookDriver {
  writes : Array[(String, Array[@moondb.Value])]
  calls : Array[String]
}

///|
fn hook_driver() -> HookDriver {
  { writes: [], calls: [], }
}

///|
pub impl @moondb.Driver for HookDriver with fn execute(self, sql, params) {
  self.writes.push((sql, params))
  self.calls.push(sql)
  { rows_affected: 1, last_insert_id: 1, }
}

///|
pub impl @moondb.Driver for HookDriver with fn query(_self, _sql, _params) {
  []
}

///|
pub impl @moondb.Driver for HookDriver with fn begin(self) -> Unit raise @moondb.DbError {
  self.calls.push("BEGIN")
}

///|
pub impl @moondb.Driver for HookDriver with fn commit(self) -> Unit raise @moondb.DbError {
  self.calls.push("COMMIT")
}

///|
pub impl @moondb.Driver for HookDriver with fn rollback(self) -> Unit raise @moondb.DbError {
  self.calls.push("ROLLBACK")
}

///|
pub impl @moondb.Driver for HookDriver with fn close(_self) -> Unit {

}

///|
pub extend HookDriver with @moondb.Driver::{
  execute,
  begin,
  ping,
  close,
  query_stream,
  commit,
  query,
  rollback,
  prepare,
  dialect,
  capabilities,
}

///|
/// A book with no author, for the write hooks that do not care about the foreign key.
fn sample_book(id : Int32) -> Book {
  { id, title: "Tide", author_id: 7, }
}

///|
test "before_insert rewrites the row the flush writes" {
  let drv = hook_driver()
  let sess = Session::new(drv)
  let model = book_model()
  sess.on(
    BeforeInsert,
    // A creation stamp, the usual reason to hook an insert.
    ctx => ctx.set_column("created_by", @moondb.Text("hook")),
  )
  sess.add_record(model, sample_book(1))
  sess.flush()
  assert_eq(drv.writes.length(), 1)
  assert_eq(
    drv.writes[0].0,
    "INSERT INTO books (id, title, author_id, created_by) VALUES (?, ?, ?, ?)",
  )
  assert_eq(drv.writes[0].1, [
    @moondb.Int(1),
    @moondb.Text("Tide"),
    @moondb.Int(7),
    @moondb.Text("hook"),
  ])
}

///|
test "before_insert can replace a value the row already carries" {
  let drv = hook_driver()
  let sess = Session::new(drv)
  let model = book_model()
  sess.on(BeforeInsert, ctx => {
    ctx.set_column("title", @moondb.Text("Normalised"))
  })
  sess.add_record(model, sample_book(2))
  sess.flush()
  assert_eq(drv.writes[0].1[1], @moondb.Text("Normalised"))
}

///|
test "after hooks see the statement that ran, with its bound values" {
  let seen : Array[String] = []
  let drv = hook_driver()
  let sess = Session::new(drv)
  let model = book_model()
  sess.on(AfterInsert, ctx => {
    seen.push(ctx.sql)
    seen.push(ctx.params.length().to_string())
  })
  sess.add_record(model, sample_book(3))
  sess.flush()
  assert_eq(seen, [
    "INSERT INTO books (id, title, author_id) VALUES (?, ?, ?)", "3",
  ])
}

///|
test "before_flush and after_flush bracket the whole batch" {
  let order : Array[String] = []
  let drv = hook_driver()
  let sess = Session::new(drv)
  let model = book_model()
  sess.on(BeforeFlush, _ctx => order.push("before_flush"))
  sess.on(AfterFlush, _ctx => order.push("after_flush"))
  sess.on(BeforeInsert, ctx => order.push("before_insert " + ctx.table))
  sess.on(AfterInsert, _ctx => order.push("after_insert"))
  sess.add_record(model, sample_book(4))
  sess.add_record(model, sample_book(5))
  sess.flush()
  assert_eq(order, [
    "before_flush", "before_insert books", "after_insert", "before_insert books",
    "after_insert", "after_flush",
  ])
}

///|
test "update and delete hooks carry the row and its key" {
  let seen : Array[String] = []
  let drv = hook_driver()
  let sess = Session::new(drv)
  let model = book_model()
  sess.on(BeforeUpdate, ctx => seen.push("before_update " + ctx.table))
  sess.on(AfterUpdate, _ctx => seen.push("after_update"))
  sess.on(BeforeDelete, ctx => {
    seen.push("before_delete " + ctx.columns.length().to_string())
  })
  sess.on(AfterDelete, _ctx => seen.push("after_delete"))
  let book = sample_book(6)
  sess.update_record(model, book)
  sess.delete_record(model, book)
  sess.flush()
  assert_eq(seen, [
    "before_update books", "after_update", "before_delete 3", "after_delete",
  ])
  assert_eq(
    drv.writes[0].0,
    "UPDATE books SET title = ?, author_id = ? WHERE id = ?",
  )
  assert_eq(drv.writes[1].0, "DELETE FROM books WHERE id = ?")
  assert_eq(drv.writes[1].1, [@moondb.Int(6)])
}

///|
test "before_commit runs before the flush, after_commit after the driver commits" {
  let drv = hook_driver()
  let sess = Session::new(drv)
  let model = book_model()
  sess.on(BeforeCommit, _ctx => drv.calls.push("hook:before_commit"))
  sess.on(AfterCommit, _ctx => drv.calls.push("hook:after_commit"))
  sess.add_record(model, sample_book(7))
  sess.commit()
  assert_eq(drv.calls[drv.calls.length() - 2], "COMMIT")
  assert_eq(drv.calls[drv.calls.length() - 1], "hook:after_commit")
  assert_eq(drv.calls.contains("hook:before_commit"), true)
}

///|
test "after_rollback runs once the driver has rolled back" {
  let drv = hook_driver()
  let sess = Session::new(drv)
  sess.on(AfterRollback, _ctx => drv.calls.push("hook:after_rollback"))
  sess.rollback()
  assert_eq(drv.calls, ["ROLLBACK", "hook:after_rollback"])
}

///|
test "a listener that raises aborts the flush before anything is written" {
  let drv = hook_driver()
  let sess = Session::new(drv)
  let model = book_model()
  sess.on(BeforeInsert, _ctx => raise @moondb.QueryError("no books today"))
  sess.add_record(model, sample_book(8))
  let refused = try {
    sess.flush()
    false
  } catch {
    @moondb.QueryError(message) => message == "no books today"
    _ => false
  }
  assert_eq(refused, true)
  assert_eq(drv.writes.length(), 0)
  // The row is still queued: a failed flush is not a lost row.
  assert_eq(sess.pending_count(), 1)
}

///|
test "listeners run in registration order and can be counted and cleared" {
  let order : Array[String] = []
  let drv = hook_driver()
  let sess = Session::new(drv)
  sess.on(BeforeInsert, _ctx => order.push("first"))
  sess.on(BeforeInsert, _ctx => order.push("second"))
  assert_eq(sess.listener_count(BeforeInsert), 2)
  assert_eq(sess.listener_count(AfterInsert), 0)
  sess.add_record(book_model(), sample_book(9))
  sess.flush()
  assert_eq(order, ["first", "second"])
  sess.off_all()
  assert_eq(sess.listener_count(BeforeInsert), 0)
}

///|
test "listeners belong to the session that registered them" {
  let drv = hook_driver()
  let watched = Session::new(drv)
  let other = Session::new(drv)
  let fired : Array[String] = []
  watched.on(BeforeInsert, _ctx => fired.push("watched"))
  other.add_record(book_model(), sample_book(10))
  other.flush()
  assert_eq(fired.length(), 0)
  watched.add_record(book_model(), sample_book(11))
  watched.flush()
  assert_eq(fired, ["watched"])
}

///|
test "insert_record fires the insert hooks too" {
  let drv = hook_driver()
  let sess = Session::new(drv)
  let fired : Array[String] = []
  sess.on(BeforeInsert, ctx => {
    fired.push("before")
    ctx.set_column("title", @moondb.Text("Stamped"))
  })
  sess.on(AfterInsert, _ctx => fired.push("after"))
  sess.insert_record(book_model(), sample_book(12)) |> ignore
  assert_eq(fired, ["before", "after"])
  assert_eq(drv.writes[0].1[1], @moondb.Text("Stamped"))
}
