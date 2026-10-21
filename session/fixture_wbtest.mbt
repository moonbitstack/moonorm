///|
struct Book {
  id : Int32
  title : String
  author_id : Int32
} derive(Eq, Debug)

///|
fn book_model() -> @schema.Model[Book] {
  @schema.Model::from_fields(
    "books",
    [
      @schema.field("id", IntType, b => Int(b.id), primary_key=true),
      @schema.field("title", TextType, b => Text(b.title), nullable=false),
      @schema.field(
        "author_id",
        IntType,
        b => Int(b.author_id),
        references=("authors", "id"),
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
  mut queries : Int32
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
fn book_row(id : Int32, title : String, author_id : Int32) -> @moondb.Row {
  {
    columns: ["id", "title", "author_id"],
    values: [Int(id), Text(title), Int(author_id)],
  }
}

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

///|
/// A `@moondb.MockDriver` with a statement log. Everything is delegated, so the echo
/// store, the row shape and the transaction bracket stay exactly the mock's; the only
/// addition is the SQL going past.
struct Tap {
  inner : @moondb.MockDriver
  sql : Array[String]
}

///|
fn Tap::new() -> Tap {
  { inner: @moondb.MockDriver::new(), sql: [], }
}

///|
impl @moondb.Driver for Tap with fn execute(
  self : Tap,
  sql : String,
  params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  self.sql.push(sql)
  self.inner.execute(sql, params)
}

///|
impl @moondb.Driver for Tap with fn query(
  self : Tap,
  sql : String,
  params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.sql.push(sql)
  self.inner.query(sql, params)
}

///|
impl @moondb.Driver for Tap with fn begin(self : Tap) -> Unit raise @moondb.DbError {
  self.inner.begin()
}

///|
impl @moondb.Driver for Tap with fn commit(self : Tap) -> Unit raise @moondb.DbError {
  self.inner.commit()
}

///|
impl @moondb.Driver for Tap with fn rollback(self : Tap) -> Unit raise @moondb.DbError {
  self.inner.rollback()
}

///|
impl @moondb.Driver for Tap with fn close(self : Tap) -> Unit {
  self.inner.close()
}

///|
/// `name` is mutable so a test can prove two `get`s handed back one instance without
/// leaning on `physical_equal`, whose result the compiler does not promise to keep
/// stable across backends.
struct Squad {
  id : Int32
  mut name : String
} derive(Eq, Debug)

///|
fn squad_model() -> @schema.Model[Squad] {
  @schema.Model::new(
    "squads",
    [
      @schema.column("id", IntType, primary_key=true),
      @schema.column("name", TextType, nullable=false),
    ],
    r => { id: r.int(0), name: r.text(1), },
    s => [("id", Int(s.id)), ("name", Text(s.name))],
  )
}

///|
pub extend Squad with Debug::{to_repr}

///|
pub extend Squad with Eq::{not_equal, equal}
