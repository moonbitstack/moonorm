// Async sessions: the same unit of work as `Session`, awaited.
//
//     moon run examples/28-async-session
//
// The driver here records what it is handed instead of talking to a server, so the
// example prints the statements an `AsyncSession` emits without needing one. Swapping
// it for a real driver is the whole change: `@pg.PgConn` and `@mysql.MysqlConn` both
// implement `@moondb.AsyncDriver`, and neither can be reached through a synchronous
// `Session` at all.

///|
/// A book, mapped to a table.
struct Book {
  id : Int32
  title : String
}

///|
fn book_model() -> @schema.Model[Book] {
  let fields : Array[@schema.Field[Book]] = [
    @schema.field("id", @schema.IntType, b => b.id, primary_key=true),
    @schema.field("title", @schema.TextType, b => b.title, nullable=false),
  ]
  @schema.Model::from_fields("books", fields, r => {
    id: r.int(0),
    title: r.text(1),
  })
}

///|
/// A driver double: it keeps the statements it was handed and answers a query with the
/// rows it was built with.
struct RecordingDriver {
  log : Array[String]
  rows : Array[@moondb.Row]
}

///|
fn RecordingDriver::new(rows : Array[@moondb.Row]) -> RecordingDriver {
  { log: [], rows, }
}

///|
impl @moondb.AsyncDriver for RecordingDriver with fn execute(
  self : RecordingDriver,
  sql : String,
  params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  if params.length() == 0 {
    self.log.push(sql)
  } else {
    self.log.push(sql + "  -- " + params.length().to_string() + " parameters")
  }
  { rows_affected: 1L, last_insert_id: 0L, }
}

///|
impl @moondb.AsyncDriver for RecordingDriver with fn query(
  self : RecordingDriver,
  sql : String,
  _params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.log.push(sql)
  self.rows
}

///|
impl @moondb.AsyncDriver for RecordingDriver with fn begin(
  self : RecordingDriver,
) -> Unit raise @moondb.DbError {
  self.log.push("BEGIN")
}

///|
impl @moondb.AsyncDriver for RecordingDriver with fn commit(
  self : RecordingDriver,
) -> Unit raise @moondb.DbError {
  self.log.push("COMMIT")
}

///|
impl @moondb.AsyncDriver for RecordingDriver with fn rollback(
  self : RecordingDriver,
) -> Unit raise @moondb.DbError {
  self.log.push("ROLLBACK")
}

///|
impl @moondb.AsyncDriver for RecordingDriver with fn close(
  self : RecordingDriver,
) -> Unit {
  self.log.push("CLOSE")
}

///|
async fn main {
  let books = book_model()
  // 1. A unit of work: queue three records, then flush them in one go.
  let driver = RecordingDriver::new([])
  let sess = @session.AsyncSession::new(driver)
  sess.begin()
  sess.add_all(books, [{ id: 1, title: "Dune", }, { id: 2, title: "Emma", }])
  sess.update_record(books, { id: 2, title: "Emma (1815)", })
  sess.flush()
  sess.commit()
  println("-- one flush, one transaction")
  for line in driver.log {
    println(line)
  }

  // 2. A savepoint: what was queued inside it leaves the queue with the rollback, so
  // the next flush cannot write a row the database has already undone.
  let savepoint_driver = RecordingDriver::new([])
  let sess = @session.AsyncSession::new(savepoint_driver)
  sess.begin()
  let sp = sess.begin_nested()
  sess.add_record(books, { id: 2, title: "Rolled back", })
  println("")
  println("-- one savepoint")
  println("queued inside it: " + sess.pending_count().to_string())
  sp.rollback()
  println("after the rollback: " + sess.pending_count().to_string())
  sess.commit()
  for line in savepoint_driver.log {
    println(line)
  }

  // 3. A read-only transaction on SQLite clears its connection flag when it ends, so
  // the next transaction on the same connection can write.
  let readonly_driver = RecordingDriver::new([])
  let sess = @session.AsyncSession::new(readonly_driver)
  sess.begin_with({ isolation: None, read_only: true, })
  sess.commit()
  println("")
  println("-- read-only transaction")
  for line in readonly_driver.log {
    println(line)
  }
}
