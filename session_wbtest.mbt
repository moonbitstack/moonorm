// Session / Model / relationship coverage against @moondb.MockDriver — the
// dependency-free reference driver. It compiles on every backend, so these run under
// `--target all` with no database and no native code. MockDriver is a naive echo
// store: `execute` appends one row built from the bound params (columns c0, c1, …),
// `query` returns every stored row, and begin/rollback/commit are a real snapshot
// bracket. That is enough to exercise the whole execution layer — the SQL the builder
// emits, the params it binds, the record mapping, and the transaction semantics —
// without pinning any one backend. Real SQL execution is covered end to end in
// moonsqlite's native integration tests.

///|
struct Team {
  id : Int
  name : String
} derive(Eq, Debug)

///|
struct Hero {
  id : Int
  name : String
  team_id : Int
} derive(Eq, Debug)

///|
fn team_model() -> Model[Team] {
  Model::new(
    "teams",
    [
      column("id", IntType, primary_key=true),
      column("name", TextType, nullable=false),
    ],
    r => { id: r.int(0), name: r.text(1), },
    t => [("id", Int(t.id)), ("name", Text(t.name))],
  )
}

///|
fn hero_model() -> Model[Hero] {
  Model::new(
    "heroes",
    [
      column("id", IntType, primary_key=true),
      column("name", TextType, nullable=false),
      column("team_id", IntType, references=Some(("teams", "id"))),
    ],
    r => { id: r.int(0), name: r.text(1), team_id: r.int(2), },
    h => {
      [("id", Int(h.id)), ("name", Text(h.name)), ("team_id", Int(h.team_id))]
    },
  )
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
  let er = sess.add(insert("t").set("name", Text("bob")).set("age", Int(30)))
  assert_eq(er.rows_affected, 1L)
  assert_eq(mock.row_count(), 1)
  // fetch(Select): the echo store hands the row back.
  let rows = sess.fetch(select("t"))
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].text(0), "bob")
  assert_eq(rows[0].int(1), 30)
  // modify/remove also append echo rows (the mock does not parse SQL) — what we
  // assert is that the calls reach the driver and report a result.
  let up = sess.modify(
    update("t").set("age", Int(31)).where_("name", "=", Text("bob")),
  )
  assert_eq(up.rows_affected, 1L)
  let del = sess.remove(delete("t").where_("age", "=", Int(31)))
  assert_eq(del.rows_affected, 1L)
  sess.close()
}

///|
test "session: transaction bracket — rollback discards, commit keeps" {
  let mock = @moondb.MockDriver::new()
  let sess = Session::new(mock)
  sess.add(insert("t").set("n", Int(1))) |> ignore
  // Work done inside a rolled-back transaction must vanish.
  sess.begin()
  sess.add(insert("t").set("n", Int(2))) |> ignore
  assert_eq(mock.row_count(), 2)
  sess.rollback()
  assert_eq(mock.row_count(), 1)
  // Work done inside a committed transaction must persist.
  sess.begin()
  sess.add(insert("t").set("n", Int(3))) |> ignore
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
  let children : Relation[Team, Hero] = has_many(heroes, "team_id", t => {
    Int(t.id)
  })
  let (sql1, p1) = children.query({ id: 1, name: "avengers", }).build()
  assert_eq(sql1, "SELECT id, name, team_id FROM heroes WHERE team_id = ?")
  assert_eq(p1.length(), 1)
  assert_eq(p1[0] == Int(1), true)
  // N:1 — a child's parent: teams.id = <child team_id>, value bound.
  let parent : Relation[Hero, Team] = belongs_to(teams, "id", h => {
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
  let parent : Relation[Hero, Team] = belongs_to(teams, "id", h => {
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
pub extend Team with Debug::{to_repr}

///|
pub extend Team with Eq::{not_equal, equal}

///|
pub extend Hero with Debug::{to_repr}

///|
pub extend Hero with Eq::{not_equal, equal}
