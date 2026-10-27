///|
/// A driver double that reports a fixed `affected` count for every `execute` and
/// remembers the last statement it saw. It is not a store; it exists solely to
/// drive `Session::modify_versioned` down both of its branches deterministically.
struct FixedDriver {
  affected : Int64
  mut last_sql : String
  mut last_params : Array[@moondb.Value]
}

///|
fn FixedDriver::new(affected : Int64) -> FixedDriver {
  { affected, last_sql: "", last_params: [], }
}

///|
pub impl @moondb.Driver for FixedDriver with fn execute(self, sql, params) {
  self.last_sql = sql
  self.last_params = params
  { rows_affected: self.affected, last_insert_id: 0, }
}

///|
pub impl @moondb.Driver for FixedDriver with fn query(_self, _sql, _params) {
  []
}

///|
pub impl @moondb.Driver for FixedDriver with fn begin(_self) -> Unit raise @moondb.DbError {

}

///|
pub impl @moondb.Driver for FixedDriver with fn commit(_self) -> Unit raise @moondb.DbError {

}

///|
pub impl @moondb.Driver for FixedDriver with fn rollback(_self) -> Unit raise @moondb.DbError {

}

///|
pub impl @moondb.Driver for FixedDriver with fn close(_self) -> Unit {

}

///|
/// The versioned UPDATE a caller writes: bump the version, guard on the one it read.
fn versioned_update(current : Int32) -> @query.Update {
  @query.update("account")
  .set("balance", Int(50))
  .set("version", Int(current + 1))
  .where_("id", "=", Int(1))
  .where_("version", "=", Int(current))
}

///|
pub extend FixedDriver with @moondb.Driver::{
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
/// An author has many books; a book belongs to one author. Fresh domain names so
/// these coexist with the Team/Hero models the other whitebox tests declare.
struct Author {
  id : Int32
  name : String
} derive(Eq, Debug)

///|
/// The author model built the declarative way — from a list of `Field`s, with no
/// hand-written `to_columns`.
fn author_model() -> @schema.Model[Author] {
  @schema.Model::from_fields(
    "authors",
    [
      @schema.field("id", IntType, a => Int(a.id), primary_key=true),
      @schema.field("name", TextType, a => Text(a.name), nullable=false),
    ],
    r => { id: r.int(0), name: r.text(1), },
  )
}

///|
fn author_row(id : Int32, name : String) -> @moondb.Row {
  { columns: ["id", "name"], values: [Int(id), Text(name)], }
}

// --- declarative Field / from_fields -------------------------------------------

///|
pub extend Author with Debug::{to_repr}

///|
pub extend Author with Eq::{not_equal, equal}

///|
struct Team {
  id : Int32
  name : String
} derive(Eq, Debug)

///|
struct Hero {
  id : Int32
  name : String
  team_id : Int32
} derive(Eq, Debug)

///|
fn team_model() -> @schema.Model[Team] {
  @schema.Model::new(
    "teams",
    [
      @schema.column("id", IntType, primary_key=true),
      @schema.column("name", TextType, nullable=false),
    ],
    r => { id: r.int(0), name: r.text(1), },
    t => [("id", Int(t.id)), ("name", Text(t.name))],
  )
}

///|
fn hero_model() -> @schema.Model[Hero] {
  @schema.Model::new(
    "heroes",
    [
      @schema.column("id", IntType, primary_key=true),
      @schema.column("name", TextType, nullable=false),
      @schema.column("team_id", IntType, references=("teams", "id")),
    ],
    r => { id: r.int(0), name: r.text(1), team_id: r.int(2), },
    h => {
      [("id", Int(h.id)), ("name", Text(h.name)), ("team_id", Int(h.team_id))]
    },
  )
}

///|
pub extend Team with Debug::{to_repr}

///|
pub extend Team with Eq::{not_equal, equal}

///|
pub extend Hero with Debug::{to_repr}

///|
pub extend Hero with Eq::{not_equal, equal}

///|
test "optimistic lock: zero rows affected is a LostUpdate" {
  let sess = Session::new(FixedDriver::new(0))
  let caught = try {
    sess.modify_versioned(versioned_update(3), what="account") |> ignore
    false
  } catch {
    LostUpdate(_) => true
    _ => false
  }
  assert_eq(caught, true)
}

///|
test "optimistic lock: a matched row returns the result, no raise" {
  let drv = FixedDriver::new(1)
  let sess = Session::new(drv)
  let res = sess.modify_versioned(versioned_update(3)) catch {
    _ => abort("a matched update must not raise")
  }
  assert_eq(res.rows_affected, 1L)
  // The version guard and the bumped version are both bound, never spliced.
  assert_eq(
    drv.last_sql,
    "UPDATE account SET balance = ?, version = ? WHERE id = ? AND version = ?",
  )
  assert_eq(drv.last_params.length(), 4)
  assert_eq(drv.last_params[1] == Int(4), true) // new version
  assert_eq(drv.last_params[3] == Int(3), true) // expected version
}

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
test "batch_query: one IN query over the distinct source keys" {
  let books = book_model()
  let children : @schema.Relation[Author, Book] = @schema.has_many(
    books,
    "author_id",
    a => Int(a.id),
  )
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
  let children : @schema.Relation[Author, Book] = @schema.has_many(
    books,
    "author_id",
    a => Int(a.id),
  )
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
  let children : @schema.Relation[Author, Book] = @schema.has_many(
    books,
    "author_id",
    a => Int(a.id),
  )
  let loaded = sess.load_batch([], children)
  assert_eq(loaded.length(), 0)
  assert_eq(spy.queries, 0)
}

///|
test "load_one_batch: one query resolves each source's parent" {
  let authors = author_model()
  let spy = SpyDriver::new([author_row(1, "asimov"), author_row(2, "banks")])
  let sess = Session::new(spy)
  let parent : @schema.Relation[Book, Author] = @schema.belongs_to(
    authors,
    "id",
    b => Int(b.author_id),
  )
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
test "session with_pool reuses one pooled connection across units of work" {
  let created = [0]
  let pool : @pool.Pool[@moondb.MockDriver] = @pool.Pool::new(() => {
    created[0] = created[0] + 1
    @moondb.MockDriver::new()
  })
  let a = Session::with_pool(pool, _s => 1)
  let b = Session::with_pool(pool, _s => 2)
  assert_eq(a, 1)
  assert_eq(b, 2)
  // The second unit of work reused the first's released connection: opened once, idle after.
  assert_eq(created[0], 1)
  assert_eq(pool.idle_count(), 1)
}

///|
test "session: raw execute binds params and query reads them back (echo store)" {
  let sess = Session::new(@moondb.MockDriver::new())
  let er = sess.execute("INSERT INTO x (a, b) VALUES (?, ?)", [
    Text("hi"),
    Int(7),
  ])
  assert_eq(er.rows_affected, 1L)
  assert_eq(er.last_insert_id, 1L)
  let rows = sess.query("SELECT * FROM x", [])
  assert_eq(rows.length(), 1)
  // MockDriver names the echoed columns c0, c1, … from the bound params.
  assert_eq(rows[0].text_by("c0"), "hi")
  assert_eq(rows[0].int_by("c1"), 7)
  sess.close()
}

///|
test "session: add/fetch/modify/remove drive the builder's SQL through the driver" {
  let mock = @moondb.MockDriver::new()
  let sess = Session::new(mock)
  // add(Insert): the built INSERT's params become the echoed row.
  let er = sess.add(
    @query.insert("t").set("name", Text("bob")).set("age", Int(30)),
  )
  assert_eq(er.rows_affected, 1L)
  assert_eq(mock.row_count(), 1)
  // fetch(Select): the echo store hands the row back.
  let rows = sess.fetch(@query.select("t"))
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].text(0), "bob")
  assert_eq(rows[0].int(1), 30)
  // modify/remove also append echo rows (the mock does not parse SQL) — what we
  // assert is that the calls reach the driver and report a result.
  let up = sess.modify(
    @query.update("t").set("age", Int(31)).where_("name", "=", Text("bob")),
  )
  assert_eq(up.rows_affected, 1L)
  let del = sess.remove(@query.delete("t").where_("age", "=", Int(31)))
  assert_eq(del.rows_affected, 1L)
  sess.close()
}

///|
test "session: transaction bracket — rollback discards, commit keeps" {
  let mock = @moondb.MockDriver::new()
  let sess = Session::new(mock)
  sess.add(@query.insert("t").set("n", Int(1))) |> ignore
  // Work done inside a rolled-back transaction must vanish.
  sess.begin()
  sess.add(@query.insert("t").set("n", Int(2))) |> ignore
  assert_eq(mock.row_count(), 2)
  sess.rollback()
  assert_eq(mock.row_count(), 1)
  // Work done inside a committed transaction must persist.
  sess.begin()
  sess.add(@query.insert("t").set("n", Int(3))) |> ignore
  sess.commit()
  assert_eq(mock.row_count(), 2)
  sess.close()
}

///|
test "session: savepoint name validation refuses non-identifiers before the DB" {
  let sess = Session::new(@moondb.MockDriver::new())
  // A valid identifier reaches the (echo) driver and returns a result.
  sess.savepoint("sp1") |> ignore
  // An injection attempt is rejected with QueryError, never issued.
  let rejected = try {
    sess.savepoint("sp; DROP TABLE teams") |> ignore
    false
  } catch {
    @moondb.QueryError(_) => true
    other => raise other
  }
  assert_eq(rejected, true)
  sess.close()
}

///|
test "model: create_table DDL + insert_record + all round-trip mapped records" {
  let sess = Session::new(@moondb.MockDriver::new())
  let teams = team_model()
  // create_table issues DDL (echoed as an empty-param row by the mock).
  sess.create_table(teams, if_not_exists=true) |> ignore
  let ddl_row_count = 1
  sess.insert_record(teams, { id: 1, name: "avengers", }) |> ignore
  sess.insert_record(teams, { id: 2, name: "x-men", }) |> ignore
  // `all` maps every echoed row back through from_row. The first row is the DDL's
  // empty echo, so filter to the two real records by decoding and checking ids.
  let rows = sess.query("SELECT * FROM teams", [])
  assert_eq(rows.length(), ddl_row_count + 2)
  // The two insert echoes carry (id, name); map just those.
  let a = teams.map_row(rows[1])
  let b = teams.map_row(rows[2])
  assert_eq(a, { id: 1, name: "avengers", })
  assert_eq(b, { id: 2, name: "x-men", })
  sess.close()
}

///|
test "model: create_table_sql renders declared columns and FK constraint" {
  let heroes = hero_model()
  let sql = heroes.create_table_sql(if_not_exists=true)
  assert_eq(
    sql, "CREATE TABLE IF NOT EXISTS heroes (id INTEGER PRIMARY KEY, name TEXT NOT NULL, team_id INTEGER REFERENCES teams(id))",
  )
}

///|
test "relation: has_many / belongs_to build the bound filter query" {
  let heroes = hero_model()
  let teams = team_model()
  // 1:N — a parent's children: heroes.team_id = <parent id>, value bound.
  let children : @schema.Relation[Team, Hero] = @schema.has_many(
    heroes,
    "team_id",
    t => Int(t.id),
  )
  let (sql1, p1) = children.query({ id: 1, name: "avengers", }).build()
  assert_eq(sql1, "SELECT id, name, team_id FROM heroes WHERE team_id = ?")
  assert_eq(p1.length(), 1)
  assert_eq(p1[0] == Int(1), true)
  // N:1 — a child's parent: teams.id = <child team_id>, value bound.
  let parent : @schema.Relation[Hero, Team] = @schema.belongs_to(teams, "id", h => {
    Int(h.team_id)
  })
  let (sql2, p2) = parent
    .query({ id: 12, name: "wolverine", team_id: 2, })
    .build()
  assert_eq(sql2, "SELECT id, name FROM teams WHERE id = ?")
  assert_eq(p2[0] == Int(2), true)
}

///|
test "session.load / load_one decode related echoed rows into records" {
  // Drive load through the mock: the source-key value is bound and the echoed row
  // (built from that bound param) is decoded back through the target model. We shape
  // the mock's store so the echoed columns line up with the target's from_row.
  let mock = @moondb.MockDriver::new()
  let sess = Session::new(mock)
  let teams = team_model()
  // Seed one row whose echoed columns are (id, name) so team_model.from_row decodes it.
  mock.execute("seed", [Int(2), Text("x-men")]) |> ignore
  let wolverine : Hero = { id: 12, name: "wolverine", team_id: 2, }
  let parent : @schema.Relation[Hero, Team] = @schema.belongs_to(teams, "id", h => {
    Int(h.team_id)
  })
  // load_one returns the first decoded record.
  let one = sess.load_one(wolverine, parent)
  assert_eq(one, Some({ id: 2, name: "x-men", }))
  // load returns every decoded record (here, the single seeded row).
  let many = sess.load(wolverine, parent)
  assert_eq(many.length(), 1)
  assert_eq(many[0], { id: 2, name: "x-men", })
  sess.close()
}

///|
test "session stream: raw and typed cursors yield the same records as the buffered forms" {
  let sess = Session::new(@moondb.MockDriver::new())
  let teams = team_model()
  sess.insert_record(teams, { id: 1, name: "avengers", }) |> ignore
  sess.insert_record(teams, { id: 2, name: "x-men", }) |> ignore
  // A raw cursor drains to exactly what fetch materialises.
  let buffered = sess.fetch(teams.select())
  let streamed = @moondb.drain(sess.stream(teams.select()))
  assert_eq(streamed.length(), buffered.length())
  assert_eq(streamed.length(), 2)
  // A typed cursor decodes each row on demand, matching `all`.
  let rs = sess.stream_as(teams, teams.select())
  let got : Array[Team] = []
  for rec = rs.next(); rec is Some(t); rec = rs.next() {
    got.push(t)
  }
  assert_eq(got, [{ id: 1, name: "avengers", }, { id: 2, name: "x-men", }])
  sess.close()
}

///|
test "identity: two gets of the same row return the same instance" {
  let tap = Tap::new()
  let sess = Session::new(tap)
  let squads = squad_model()
  // Seed a row shaped (id, name) so squad_model.from_row decodes it. Seeding goes
  // straight at the mock, so it does not show up in the tap's log.
  tap.inner.execute("seed", [Int(1), Text("avengers")]) |> ignore
  let a = match sess.get(squads, Int(1)) {
    Some(r) => r
    None => fail("row 1 should load")
  }
  let b = match sess.get(squads, Int(1)) {
    Some(r) => r
    None => fail("row 1 should still load")
  }
  assert_eq(physical_equal(a, b), true)
  // The same instance, proven without physical_equal: a write through one is visible
  // through the other.
  a.name = "renamed"
  assert_eq(b.name, "renamed")
  // Only the first get queried; the second was answered by the identity map.
  assert_eq(tap.sql, ["SELECT id, name FROM squads WHERE id = ? LIMIT 1"])
  sess.close()
}

///|
test "identity: expunge drops the record, so the next get reads a fresh one" {
  let tap = Tap::new()
  let sess = Session::new(tap)
  let squads = squad_model()
  tap.inner.execute("seed", [Int(1), Text("avengers")]) |> ignore
  let a = match sess.get(squads, Int(1)) {
    Some(r) => r
    None => fail("row 1 should load")
  }
  a.name = "renamed"
  sess.expunge(squads, a)
  let b = match sess.get(squads, Int(1)) {
    Some(r) => r
    None => fail("row 1 should reload")
  }
  assert_eq(physical_equal(a, b), false)
  assert_eq(b.name, "avengers")
  assert_eq(tap.sql.length(), 2)
  sess.close()
}
