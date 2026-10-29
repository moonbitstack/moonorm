///|
test "from_fields: a fetched row maps back into the record via from_row" {
  let books = book_model()
  let rec = books.map_row(book_row(1, "It", 2))
  assert_eq(rec, { id: 1, title: "It", author_id: 2, })
  assert_eq(@schema.field("id", IntType, (b : Book) => b.id).name(), "id")
}

// --- IN (values) predicate ------------------------------------------------------

///|
test "begin_nested: auto-named savepoints track depth and issue the right SQL" {
  let spy = SpyDriver::new([])
  let sess = Session::new(spy)
  assert_eq(sess.savepoint_depth(), 0)
  let outer = sess.begin_nested()
  assert_eq(outer.name(), "moonorm_sp_1")
  assert_eq(outer.depth(), 1)
  assert_eq(sess.savepoint_depth(), 1)
  let inner = sess.begin_nested()
  assert_eq(inner.name(), "moonorm_sp_2")
  assert_eq(inner.depth(), 2)
  assert_eq(sess.savepoint_depth(), 2)
  // Roll the inner one back (ROLLBACK TO then RELEASE), then release the outer.
  inner.rollback()
  assert_eq(sess.savepoint_depth(), 1)
  outer.release()
  assert_eq(sess.savepoint_depth(), 0)
  assert_eq(spy.log, [
    "SAVEPOINT moonorm_sp_1", "SAVEPOINT moonorm_sp_2", "ROLLBACK TO SAVEPOINT moonorm_sp_2",
    "RELEASE SAVEPOINT moonorm_sp_2", "RELEASE SAVEPOINT moonorm_sp_1",
  ])
}

///|
test "TxOptions::to_sql: standard SET TRANSACTION for Postgres/MySQL" {
  let opts = { isolation: Some(Serializable), read_only: true, }
  assert_eq(opts.to_sql(Postgres), [
    "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", "SET TRANSACTION READ ONLY",
  ])
  assert_eq(
    { isolation: Some(ReadCommitted), read_only: false, }.to_sql(Mysql),
    ["SET TRANSACTION ISOLATION LEVEL READ COMMITTED"],
  )
  assert_eq(TxOptions::default().to_sql(Postgres), [])
}

///|
test "TxOptions::to_sql: SQLite renders PRAGMAs, only for what it supports" {
  assert_eq(
    { isolation: Some(ReadUncommitted), read_only: true, }.to_sql(Sqlite),
    ["PRAGMA read_uncommitted = 1", "PRAGMA query_only = 1"],
  )
  // SQLite is serializable by default, so a stronger level needs no statement.
  assert_eq(
    { isolation: Some(Serializable), read_only: false, }.to_sql(Sqlite),
    [],
  )
}
