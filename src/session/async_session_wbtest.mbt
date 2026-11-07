// The asynchronous session, driven by a driver double so the statements and the
// ordering can be read back. What needs a real server — that two sessions really
// overlap on the wire — is in `integration/realdb`.

///|
/// A driver double that logs every statement it is handed and replays a fixed row set,
/// exactly as `SpyDriver` does for the synchronous session, so a test can compare the
/// two logs and see one unit of work.
struct AsyncSpyDriver {
  log : Array[String]
  rows : Array[@moondb.Row]
  mut queries : Int32
}

///|
fn AsyncSpyDriver::new(rows : Array[@moondb.Row]) -> AsyncSpyDriver {
  { log: [], rows, queries: 0, }
}

///|
impl @moondb.AsyncDriver for AsyncSpyDriver with fn execute(
  self : AsyncSpyDriver,
  sql : String,
  _params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  self.log.push(sql)
  { rows_affected: 1L, last_insert_id: 0L, }
}

///|
impl @moondb.AsyncDriver for AsyncSpyDriver with fn query(
  self : AsyncSpyDriver,
  sql : String,
  _params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.log.push(sql)
  self.queries = self.queries + 1
  self.rows
}

///|
impl @moondb.AsyncDriver for AsyncSpyDriver with fn begin(self : AsyncSpyDriver) -> Unit raise @moondb.DbError {
  self.log.push("BEGIN")
}

///|
impl @moondb.AsyncDriver for AsyncSpyDriver with fn commit(
  self : AsyncSpyDriver,
) -> Unit raise @moondb.DbError {
  self.log.push("COMMIT")
}

///|
impl @moondb.AsyncDriver for AsyncSpyDriver with fn rollback(
  self : AsyncSpyDriver,
) -> Unit raise @moondb.DbError {
  self.log.push("ROLLBACK")
}

///|
impl @moondb.AsyncDriver for AsyncSpyDriver with fn close(self : AsyncSpyDriver) -> Unit {
  self.log.push("CLOSE")
}

///|
/// The same unit of work run through both sessions: a queued insert, an update and a
/// delete must reach the driver as the same statements in the same order, or the two
/// types are not the same interface written twice.
async test "async session: the same unit of work emits the same statements as the sync one" {
  let books = book_model()
  let sync_driver = SpyDriver::new([])
  let sync_sess = Session::new(sync_driver)
  sync_sess.add_record(books, { id: 1, title: "It", author_id: 2, })
  sync_sess.update_record(books, { id: 3, title: "Dune", author_id: 2, })
  sync_sess.delete_record(books, { id: 4, title: "Emma", author_id: 2, })
  sync_sess.flush()

  let async_driver = AsyncSpyDriver::new([])
  let async_sess = AsyncSession::new(async_driver)
  async_sess.add_record(books, { id: 1, title: "It", author_id: 2, })
  async_sess.update_record(books, { id: 3, title: "Dune", author_id: 2, })
  async_sess.delete_record(books, { id: 4, title: "Emma", author_id: 2, })
  async_sess.flush()

  assert_eq(async_driver.log, sync_driver.log)
  assert_eq(async_driver.log.length(), 3)
  assert_eq(async_sess.pending_count(), 0)
}

///|
async test "async session: a transaction rolls back and keeps the session usable" {
  let driver = AsyncSpyDriver::new([])
  let sess = AsyncSession::new(driver)
  sess.begin()
  sess.add_record(book_model(), { id: 1, title: "It", author_id: 1, })
  sess.rollback()
  assert_eq(sess.pending_count(), 0)
  assert_eq(driver.log, ["BEGIN", "ROLLBACK"])
  // Still usable: a second transaction brackets its own statements.
  sess.begin()
  sess.commit()
  assert_eq(driver.log, ["BEGIN", "ROLLBACK", "BEGIN", "COMMIT"])
}

///|
async test "async session: begin_nested tracks depth and a rollback drops the loaded row" {
  let books = book_model()
  let driver = AsyncSpyDriver::new([book_row(1, "It", 2)])
  let sess = AsyncSession::new(driver)
  sess.begin()
  assert_eq(sess.get(books, @moondb.Int(1)).unwrap().title, "It")
  let sp = sess.begin_nested()
  assert_eq(sp.depth(), 1)
  assert_eq(sess.savepoint_depth(), 1)
  // Loaded again inside the savepoint: the identity map already holds it, so this is
  // the same record and no second query.
  assert_eq(sess.get(books, @moondb.Int(1)).unwrap().title, "It")
  assert_eq(driver.queries, 1)
  sp.rollback()
  assert_eq(sess.savepoint_depth(), 0)
  // The restore put the map back to what it held when the savepoint opened, so the
  // row is still there and still costs no query.
  assert_eq(sess.get(books, @moondb.Int(1)).unwrap().title, "It")
  assert_eq(driver.queries, 1)
  assert_eq(driver.log, [
    "BEGIN", "SELECT id, title, author_id FROM books WHERE id = ? LIMIT 1", "SAVEPOINT moonorm_sp_1",
    "ROLLBACK TO SAVEPOINT moonorm_sp_1", "RELEASE SAVEPOINT moonorm_sp_1",
  ])
}

///|
async test "async session: begin_with read_only puts query_only back when it ends" {
  let driver = AsyncSpyDriver::new([])
  let sess = AsyncSession::new(driver)
  sess.begin_with({ isolation: None, read_only: true, })
  sess.commit()
  assert_eq(driver.log, [
    "PRAGMA query_only = 1", "BEGIN", "COMMIT", "PRAGMA query_only = 0",
  ])
  // On a backend whose read-only marker lasts one transaction there is nothing to undo.
  let pg = AsyncSpyDriver::new([])
  let pg_sess = AsyncSession::new(pg, dialect=Postgres)
  pg_sess.begin_with({ isolation: None, read_only: true, })
  pg_sess.rollback()
  assert_eq(pg.log, ["BEGIN", "SET TRANSACTION READ ONLY", "ROLLBACK"])
}

///|
async test "async session: a write queued inside a savepoint leaves the queue on rollback" {
  let books = book_model()
  let driver = AsyncSpyDriver::new([])
  let sess = AsyncSession::new(driver)
  sess.begin()
  let sp = sess.begin_nested()
  sess.add_record(books, { id: 7, title: "Queued", author_id: 1, })
  assert_eq(sess.pending_count(), 1)
  sp.rollback()
  assert_eq(sess.pending_count(), 0)
  // Flushing after the rollback must not replay the undone insert.
  sess.flush()
  assert_eq(
    driver.log.contains(
      "INSERT INTO books (id, title, author_id) VALUES (?, ?, ?)",
    ),
    false,
  )
}
