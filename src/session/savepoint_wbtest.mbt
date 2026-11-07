// Savepoints and transaction options change state the database does not own alone:
// the session's queues and identity map, and the connection's own PRAGMAs. These are
// the tests that hold those two to the SQL.

///|
test "savepoint rollback: an updated record goes back to the value the database rolled back to" {
  let books = book_model()
  let spy = SpyDriver::new([book_row(1, "It", 2)])
  let sess = Session::new(spy)
  sess.begin()
  assert_eq(sess.get(books, @moondb.Int(1)).unwrap().title, "It")
  let sp = sess.begin_nested()
  sess.update_record(books, { id: 1, title: "Changed", author_id: 2, })
  sess.flush()
  // The flush refreshed the identity map, so a `get` here is the updated record —
  // and costs no query.
  assert_eq(sess.get(books, @moondb.Int(1)).unwrap().title, "Changed")
  assert_eq(spy.queries, 1)
  sp.rollback()
  // The row is back to "It" in the database, so the copy handed out has to agree.
  // Reading it out of the map (rather than refetching) is what proves the map itself
  // was put back.
  assert_eq(sess.get(books, @moondb.Int(1)).unwrap().title, "It")
  assert_eq(spy.queries, 1)
}

///|
test "savepoint rollback: a row inserted inside the savepoint stops being reachable" {
  let books = book_model()
  // The database is empty: the insert that would have made the row is rolled back, so
  // a read that reaches the server finds nothing.
  let spy = SpyDriver::new([])
  let sess = Session::new(spy)
  sess.begin()
  let sp = sess.begin_nested()
  sess.add_record(books, { id: 9, title: "Gone", author_id: 1, })
  sess.flush()
  // Reachable from the identity map the flush filled in, with no query.
  assert_eq(sess.get(books, @moondb.Int(9)).unwrap().title, "Gone")
  assert_eq(spy.queries, 0)
  sp.rollback()
  // The map forgot the row, so the read goes to the database — which no longer has it.
  assert_eq(sess.get(books, @moondb.Int(9)) is None, true)
  assert_eq(spy.queries, 1)
}

///|
test "rollback_to by name rewinds the session as well as the database" {
  let books = book_model()
  let spy = SpyDriver::new([])
  let sess = Session::new(spy)
  sess.begin()
  sess.savepoint("checkpoint") |> ignore
  sess.add_record(books, { id: 5, title: "Queued", author_id: 1, })
  assert_eq(sess.pending_count(), 1)
  sess.rollback_to("checkpoint") |> ignore
  assert_eq(sess.pending_count(), 0)
  assert_eq(sess.savepoint_depth(), 1)
  sess.release("checkpoint") |> ignore
  assert_eq(sess.savepoint_depth(), 0)
}

///|
test "a released savepoint keeps its work, and an outer rollback still drops it" {
  let books = book_model()
  let spy = SpyDriver::new([])
  let sess = Session::new(spy)
  sess.begin()
  let outer = sess.begin_nested()
  let inner = sess.begin_nested()
  sess.add_record(books, { id: 2, title: "Inner", author_id: 1, })
  inner.release()
  // Released into the outer savepoint: still queued, one write.
  assert_eq(sess.pending_count(), 1)
  assert_eq(sess.savepoint_depth(), 1)
  outer.rollback()
  // The outer rollback undoes the work the released savepoint folded in.
  assert_eq(sess.pending_count(), 0)
}

///|
test "begin_with read_only: SQLite's query_only is cleared when the transaction ends" {
  let spy = SpyDriver::new([])
  let sess = Session::new(spy)
  sess.begin_with({ isolation: None, read_only: true, })
  assert_eq(spy.log, ["PRAGMA query_only = 1", "BEGIN"])
  sess.execute("SELECT 1", []) |> ignore
  sess.rollback()
  assert_eq(spy.log, [
    "PRAGMA query_only = 1", "BEGIN", "SELECT 1", "ROLLBACK", "PRAGMA query_only = 0",
  ])
  // A second transaction on the same session starts writable again.
  sess.begin()
  sess.commit()
  assert_eq(spy.log.contains("PRAGMA query_only = 0"), true)
}

///|
test "begin_with: a commit clears the pragma before any after-commit listener runs" {
  let spy = SpyDriver::new([])
  let sess = Session::new(spy)
  sess.on(AfterCommit, _ctx => spy.log.push("after-commit"))
  sess.begin_with({ isolation: None, read_only: true, })
  sess.commit()
  assert_eq(spy.log, [
    "PRAGMA query_only = 1", "BEGIN", "COMMIT", "PRAGMA query_only = 0", "after-commit",
  ])
}

///|
test "begin_with: read_uncommitted is put back too, and Postgres needs no restore" {
  let spy = SpyDriver::new([])
  let sess = Session::new(spy)
  sess.begin_with({ isolation: Some(ReadUncommitted), read_only: false, })
  sess.commit()
  assert_eq(spy.log, [
    "PRAGMA read_uncommitted = 1", "BEGIN", "COMMIT", "PRAGMA read_uncommitted = 0",
  ])
  // `SET TRANSACTION` lasts exactly one transaction, so nothing is undone.
  let pg = SpyDriver::new([])
  let pg_sess = Session::new(pg, dialect=Postgres)
  pg_sess.begin_with({ isolation: None, read_only: true, })
  pg_sess.commit()
  assert_eq(pg.log, ["BEGIN", "SET TRANSACTION READ ONLY", "COMMIT"])
}

///|
test "merge: a record the database already has is queued as an update" {
  let books = book_model()
  let spy = SpyDriver::new([book_row(1, "It", 2)])
  let sess = Session::new(spy)
  sess.merge(books, { id: 1, title: "It, revised", author_id: 2, }) |> ignore
  assert_eq(sess.dirty_count(), 1)
  assert_eq(sess.pending_count(), 0)
  // A key the database does not have is an insert. The empty driver stands for a table
  // without that row.
  let empty = SpyDriver::new([])
  let other = Session::new(empty)
  other.merge(books, { id: 2, title: "New", author_id: 2, }) |> ignore
  assert_eq(other.pending_count(), 1)
  assert_eq(other.dirty_count(), 0)
}

///|
test "refresh: the record is re-read and the identity map follows" {
  let books = book_model()
  let spy = SpyDriver::new([book_row(1, "From the server", 2)])
  let sess = Session::new(spy)
  let loaded = sess.get(books, @moondb.Int(1)).unwrap()
  assert_eq(loaded.title, "From the server")
  let fresh = sess.refresh(books, { id: 1, title: "Stale", author_id: 2, })
  assert_eq(fresh.title, "From the server")
  // The refreshed record replaced the stale one under the same key.
  assert_eq(sess.get(books, @moondb.Int(1)).unwrap().title, "From the server")
}
