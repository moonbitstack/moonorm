// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Round-7 coverage: the declarative Field/from_fields model path, the IN-values
// builder predicate, N+1-avoiding batch loading, depth-tracked nested savepoints,
// and isolation-level transaction options. Everything runs on every backend against
// hand-built driver doubles (a spy that logs the SQL it is issued and replays a
// fixed result set), so the SQL, the parameter binding, the row grouping, and the
// transaction bookkeeping are all asserted without a database. Real execution over
// SQLite is covered in the integration suite.

///|
/// An author has many books; a book belongs to one author. Fresh domain names so
/// these coexist with the Team/Hero models the other whitebox tests declare.
struct Author {
  id : Int
  name : String
} derive(Eq, Debug)

///|
struct Book {
  id : Int
  title : String
  author_id : Int
} derive(Eq, Debug)

///|
/// The author model built the declarative way — from a list of `Field`s, with no
/// hand-written `to_columns`.
fn author_model() -> Model[Author] {
  Model::from_fields(
    "authors",
    [
      field("id", IntType, a => Int(a.id), primary_key=true),
      field("name", TextType, a => Text(a.name), nullable=false),
    ],
    r => { id: r.int(0), name: r.text(1), },
  )
}

///|
fn book_model() -> Model[Book] {
  Model::from_fields(
    "books",
    [
      field("id", IntType, b => Int(b.id), primary_key=true),
      field("title", TextType, b => Text(b.title), nullable=false),
      field(
        "author_id",
        IntType,
        b => Int(b.author_id),
        references=Some(("authors", "id")),
      ),
    ],
    r => { id: r.int(0), title: r.text(1), author_id: r.int(2), },
  )
}

///|
/// A driver double that logs every statement it is handed (executes as `sql`,
/// `begin`/`commit`/`rollback` as those keywords) and replays a fixed row set from
/// `query`, counting the queries so a test can prove a batch load makes exactly one
/// round trip. It parses nothing.
struct SpyDriver {
  log : Array[String]
  rows : Array[@moondb.Row]
  mut queries : Int
}

///|
fn SpyDriver::new(rows : Array[@moondb.Row]) -> SpyDriver {
  { log: [], rows, queries: 0, }
}

///|
pub impl @moondb.Driver for SpyDriver with fn execute(self, sql, _params) {
  self.log.push(sql)
  { rows_affected: 1, last_insert_id: 0, }
}

///|
pub impl @moondb.Driver for SpyDriver with fn query(self, _sql, _params) {
  self.queries = self.queries + 1
  self.rows
}

///|
pub impl @moondb.Driver for SpyDriver with fn begin(self) -> Unit raise @moondb.DbError {
  self.log.push("BEGIN")
}

///|
pub impl @moondb.Driver for SpyDriver with fn commit(self) -> Unit raise @moondb.DbError {
  self.log.push("COMMIT")
}

///|
pub impl @moondb.Driver for SpyDriver with fn rollback(self) -> Unit raise @moondb.DbError {
  self.log.push("ROLLBACK")
}

///|
pub impl @moondb.Driver for SpyDriver with fn close(_self) -> Unit {

}

///|
/// One result row with named columns, so `Row::by_name` (which the batch loader uses
/// to bucket children) resolves the foreign-key column.
fn book_row(id : Int, title : String, author_id : Int) -> @moondb.Row {
  {
    columns: ["id", "title", "author_id"],
    values: [Int(id), Text(title), Int(author_id)],
  }
}

///|
fn author_row(id : Int, name : String) -> @moondb.Row {
  { columns: ["id", "name"], values: [Int(id), Text(name)], }
}

// --- declarative Field / from_fields -------------------------------------------

///|
test "from_fields: columns, DDL, and insert binding are derived from the field list" {
  let authors = author_model()
  assert_eq(authors.column_names(), ["id", "name"])
  assert_eq(
    authors.create_table_sql(),
    "CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
  )
  let books = book_model()
  assert_eq(
    books.create_table_sql(if_not_exists=true),
    "CREATE TABLE IF NOT EXISTS books (id INTEGER PRIMARY KEY, title TEXT NOT NULL, author_id INTEGER REFERENCES authors(id))",
  )
  // to_columns was never hand-written; the fields' encoders produce it.
  let (isql, ivals) = books
    .insert_of({ id: 7, title: "Dune", author_id: 3, })
    .build()
  assert_eq(isql, "INSERT INTO books (id, title, author_id) VALUES (?, ?, ?)")
  assert_eq(ivals.length(), 3)
  assert_eq(ivals[0] == Int(7), true)
  assert_eq(ivals[1] == Text("Dune"), true)
  assert_eq(ivals[2] == Int(3), true)
}

///|
test "from_fields: a fetched row maps back into the record via from_row" {
  let books = book_model()
  let rec = books.map_row(book_row(1, "It", 2))
  assert_eq(rec, { id: 1, title: "It", author_id: 2, })
  assert_eq(field("id", IntType, (b : Book) => Int(b.id)).name(), "id")
}

// --- IN (values) predicate ------------------------------------------------------

///|
test "where_in_values: renders placeholders and binds each value in text order" {
  let (sql, params) = select("books")
    .column("id")
    .where_("shelf", "=", Text("scifi"))
    .where_in_values("author_id", [Int(1), Int(2), Int(3)])
    .build()
  assert_eq(
    sql, "SELECT id FROM books WHERE shelf = ? AND author_id IN (?, ?, ?)",
  )
  // Scalar predicate first, then each IN value — the SQL text order.
  assert_eq(params.length(), 4)
  assert_eq(params[0] == Text("scifi"), true)
  assert_eq(params[1] == Int(1), true)
  assert_eq(params[3] == Int(3), true)
}

///|
test "where_not_in_values and the empty set" {
  let (sql1, p1) = select("t").where_not_in_values("k", [Int(9)]).build()
  assert_eq(sql1, "SELECT * FROM t WHERE k NOT IN (?)")
  assert_eq(p1[0] == Int(9), true)
  // The empty set constant-folds: empty IN matches nothing (1 = 0), empty NOT IN
  // matches everything (1 = 1) — never `IN (NULL)`, which is wrong under NULL logic.
  let (sql2, p2) = select("t").where_in_values("k", []).build()
  assert_eq(sql2, "SELECT * FROM t WHERE 1 = 0")
  assert_eq(p2.length(), 0)
  let (sql3, p3) = select("t").where_not_in_values("k", []).build()
  assert_eq(sql3, "SELECT * FROM t WHERE 1 = 1")
  assert_eq(p3.length(), 0)
}

///|
test "where_in_values sits between scalar and subquery predicates in param order" {
  let sub = select("banned").column("id").where_("active", "=", Bool(true))
  let (sql, params) = select("t")
    .where_("a", "=", Int(1))
    .where_in_values("b", [Int(2), Int(3)])
    .where_in("c", sub)
    .build()
  assert_eq(
    sql, "SELECT * FROM t WHERE a = ? AND b IN (?, ?) AND c IN (SELECT id FROM banned WHERE active = ?)",
  )
  // scalar(1) -> in-values(2,3) -> subquery(true): exactly the text order.
  assert_eq(params.length(), 4)
  assert_eq(params[0] == Int(1), true)
  assert_eq(params[1] == Int(2), true)
  assert_eq(params[2] == Int(3), true)
  assert_eq(params[3] == Bool(true), true)
}

// --- N+1-avoiding batch load ----------------------------------------------------

///|
test "batch_query: one IN query over the distinct source keys" {
  let books = book_model()
  let children : Relation[Author, Book] = has_many(books, "author_id", a => {
    Int(a.id)
  })
  // Two authors share id 1 (a duplicate key) — the IN list must carry it once.
  let (sql, params) = children
    .batch_query([
      { id: 1, name: "a", },
      { id: 2, name: "b", },
      { id: 1, name: "c", },
    ])
    .build()
  assert_eq(
    sql, "SELECT id, title, author_id FROM books WHERE author_id IN (?, ?)",
  )
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Int(1), true)
  assert_eq(params[1] == Int(2), true)
}

///|
test "load_batch: one query fetches every child, bucketed to its parent" {
  let books = book_model()
  let spy = SpyDriver::new([
    book_row(10, "A1", 1),
    book_row(11, "A2", 1),
    book_row(12, "B1", 2),
  ])
  let sess = Session::new(spy)
  let children : Relation[Author, Book] = has_many(books, "author_id", a => {
    Int(a.id)
  })
  let authors : Array[Author] = [
    { id: 1, name: "asimov", },
    { id: 2, name: "banks", },
    { id: 3, name: "clarke", }, // no books
  ]
  let loaded = sess.load_batch(authors, children)
  // Exactly one round trip — the whole point of batching.
  assert_eq(spy.queries, 1)
  assert_eq(loaded.length(), 3)
  assert_eq(loaded[0].length(), 2)
  assert_eq(loaded[0][0], { id: 10, title: "A1", author_id: 1, })
  assert_eq(loaded[0][1], { id: 11, title: "A2", author_id: 1, })
  assert_eq(loaded[1].length(), 1)
  assert_eq(loaded[1][0], { id: 12, title: "B1", author_id: 2, })
  assert_eq(loaded[2].length(), 0) // clarke has none
}

///|
test "load_batch: empty sources makes no query" {
  let spy = SpyDriver::new([])
  let sess = Session::new(spy)
  let books = book_model()
  let children : Relation[Author, Book] = has_many(books, "author_id", a => {
    Int(a.id)
  })
  let loaded = sess.load_batch([], children)
  assert_eq(loaded.length(), 0)
  assert_eq(spy.queries, 0)
}

///|
test "load_one_batch: one query resolves each source's parent" {
  let authors = author_model()
  let spy = SpyDriver::new([author_row(1, "asimov"), author_row(2, "banks")])
  let sess = Session::new(spy)
  let parent : Relation[Book, Author] = belongs_to(authors, "id", b => {
    Int(b.author_id)
  })
  let books : Array[Book] = [
    { id: 100, title: "Foundation", author_id: 1, },
    { id: 101, title: "Culture", author_id: 2, },
    { id: 102, title: "Orphan", author_id: 9, }, // no matching author
  ]
  let parents = sess.load_one_batch(books, parent)
  assert_eq(spy.queries, 1)
  assert_eq(parents.length(), 3)
  assert_eq(parents[0], Some({ id: 1, name: "asimov", }))
  assert_eq(parents[1], Some({ id: 2, name: "banks", }))
  assert_eq(parents[2], None)
}

// --- depth-tracked nested savepoints -------------------------------------------

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
test "begin_nested: release and rollback are idempotent and terminal" {
  let spy = SpyDriver::new([])
  let sess = Session::new(spy)
  let sp = sess.begin_nested()
  sp.release()
  assert_eq(sess.savepoint_depth(), 0)
  // Second finish is a no-op: no extra SQL, depth stays put (does not go negative).
  sp.release()
  sp.rollback()
  assert_eq(sess.savepoint_depth(), 0)
  assert_eq(spy.log, [
    "SAVEPOINT moonorm_sp_1", "RELEASE SAVEPOINT moonorm_sp_1",
  ])
}

// --- isolation-level transaction options ---------------------------------------

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

///|
test "begin_with: SET TRANSACTION lands after BEGIN on Postgres, before it on MySQL" {
  let opts = { isolation: Some(Serializable), read_only: false, }
  let pg = SpyDriver::new([])
  Session::new(pg).begin_with(opts)
  assert_eq(pg.log, ["BEGIN", "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"])
  let my = SpyDriver::new([])
  Session::new(my).begin_with(opts, dialect=Mysql)
  assert_eq(my.log, ["SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", "BEGIN"])
}

///|
pub extend Author with Debug::{to_repr}

///|
pub extend Author with Eq::{not_equal, equal}

///|
pub extend Book with Debug::{to_repr}

///|
pub extend Book with Eq::{not_equal, equal}

///|
pub extend SpyDriver with @moondb.Driver::{
  execute,
  begin,
  ping,
  close,
  query_stream,
  commit,
  query,
  rollback,
}
