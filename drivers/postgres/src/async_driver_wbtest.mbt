// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Coverage for the @moondb.AsyncDriver seam. The first half needs no server: a
// fake driver stands in for the wire, which is what proves the trait is
// implementable out of tree and exercises the defaults moondb ships (`ping`,
// `query_stream`). The second half runs the same trait object against a real
// PostgreSQL and is gated on MOON_PG_TEST like the rest of the suite.

///|
/// A driver that answers from memory instead of a socket. It records the SQL it
/// was handed so a test can assert the seam routed the call, and `fail` flips
/// every fallible method to raising so the error paths are reachable too.
struct FakeDriver {
  log : Array[String]
  rows : Array[Row]
  mut fail : Bool
}

///|
fn FakeDriver::new(rows : Array[Row]) -> FakeDriver {
  { log: [], rows, fail: false, }
}

///|
impl @moondb.AsyncDriver for FakeDriver with fn execute(
  self : FakeDriver,
  sql : String,
  params : Array[Value],
) -> ExecResult raise DbError {
  self.log.push("execute:" + sql + ":" + params.length().to_string())
  if self.fail {
    raise @moondb.QueryError("fake execute failed")
  }
  { rows_affected: 1L, last_insert_id: 233L, }
}

///|
impl @moondb.AsyncDriver for FakeDriver with fn query(
  self : FakeDriver,
  sql : String,
  params : Array[Value],
) -> Array[Row] raise DbError {
  self.log.push("query:" + sql + ":" + params.length().to_string())
  if self.fail {
    raise @moondb.QueryError("fake query failed")
  }
  self.rows
}

///|
impl @moondb.AsyncDriver for FakeDriver with fn begin(self : FakeDriver) -> Unit raise DbError {
  self.log.push("begin")
}

///|
impl @moondb.AsyncDriver for FakeDriver with fn commit(self : FakeDriver) -> Unit raise DbError {
  self.log.push("commit")
}

///|
impl @moondb.AsyncDriver for FakeDriver with fn rollback(self : FakeDriver) -> Unit raise DbError {
  self.log.push("rollback")
}

///|
impl @moondb.AsyncDriver for FakeDriver with fn close(self : FakeDriver) -> Unit {
  self.log.push("close")
}

///|
fn row(id : Int32, name : String) -> Row {
  { columns: ["id", "name"], values: [@moondb.Int(id), @moondb.Text(name)], }
}

///|
async test "async seam: a fake driver drives every method through the trait object" {
  let fake = FakeDriver::new([row(1, "heke1228"), row(2, "qwq")])
  let drv : &@moondb.AsyncDriver = fake
  let r = drv.execute("INSERT INTO t VALUES (?)", [@moondb.Int(233)])
  assert_eq(r.rows_affected, 1L)
  assert_eq(r.last_insert_id, 233L)
  let rows = drv.query("SELECT id, name FROM t", [])
  assert_eq(rows.length(), 2)
  assert_eq(rows[0].text_by("name"), "heke1228")
  drv.begin()
  drv.rollback()
  drv.commit()
  drv.close()
  assert_eq(fake.log, [
    "execute:INSERT INTO t VALUES (?):1", "query:SELECT id, name FROM t:0", "begin",
    "rollback", "commit", "close",
  ])
}

///|
async test "async seam: default query_stream yields exactly what query returns" {
  let fake = FakeDriver::new([row(1, "emm"), row(2, "hhh"), row(3, "orz")])
  let drv : &@moondb.AsyncDriver = fake
  // FakeDriver does not override query_stream, so this is moondb's default:
  // materialise via `query`, hand back an AsyncArrayCursor.
  let cur = drv.query_stream("SELECT id, name FROM t WHERE id > ?", [
    @moondb.Int(0),
  ])
  // The default has to forward the statement and its params to `query` untouched.
  // Asserting only on the rows would miss that: a default that dropped the params
  // or substituted its own SQL still hands back this fake's rows.
  assert_eq(fake.log, ["query:SELECT id, name FROM t WHERE id > ?:1"])
  // Assert the row is there before unwrapping it, so a cursor that yields nothing
  // fails here by name instead of panicking somewhere in the runtime.
  let first = cur.next()
  assert_eq(first is Some(_), true)
  assert_eq(first.unwrap().text_by("name"), "emm")
  let rest = @moondb.drain_async(cur)
  assert_eq(rest.length(), 2)
  assert_eq(rest[0].text_by("name"), "hhh")
  assert_eq(rest[1].text_by("name"), "orz")
  // Exhausted, and idempotent afterwards.
  assert_eq(cur.next() is None, true)
  cur.close()
  assert_eq(cur.next() is None, true)
}

///|
async test "async seam: closing a half-read cursor ends it" {
  let fake = FakeDriver::new([row(1, "emm"), row(2, "hhh"), row(3, "orz")])
  let drv : &@moondb.AsyncDriver = fake
  let cur = drv.query_stream("SELECT id, name FROM t", [])
  let first = cur.next()
  assert_eq(first is Some(_), true)
  // Abandoned with two rows still unread: close must end it, not leave it mid-way.
  cur.close()
  assert_eq(cur.next() is None, true)
}

///|
async test "async seam: default ping round-trips, and reports false instead of raising" {
  let fake = FakeDriver::new([row(1, "ok")])
  let drv : &@moondb.AsyncDriver = fake
  assert_eq(drv.ping(), true)
  assert_eq(fake.log, ["query:SELECT 1:0"])
  // A driver whose query raises must come back unhealthy, not raise: a pool's
  // pre_ping calls this on every idle connection.
  fake.fail = true
  assert_eq(drv.ping(), false)
}

///|
async test "async seam: drain_async on an empty result gives an empty array" {
  let fake = FakeDriver::new([])
  let drv : &@moondb.AsyncDriver = fake
  assert_eq(@moondb.drain_async(drv.query_stream("SELECT 1", [])).length(), 0)
}

///|
async test "integration: PgConn drives a statement and a query through @moondb.AsyncDriver" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let conn = pg_open()
  // Everything below goes through the seam, not PgConn's own methods: this is the
  // test that the wire driver really satisfies the trait end to end.
  let drv : &@moondb.AsyncDriver = conn
  assert_eq(drv.ping(), true)
  drv.execute("DROP TABLE IF EXISTS moon_pg_async", []) |> ignore
  drv.execute("CREATE TABLE moon_pg_async (id int, name text)", []) |> ignore
  let ins = drv.execute("INSERT INTO moon_pg_async VALUES (?, ?)", [
    @moondb.Int(1),
    @moondb.Text("heke1228"),
  ])
  assert_eq(ins.rows_affected, 1L)
  let rows = drv.query("SELECT id, name FROM moon_pg_async ORDER BY id", [])
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].int_by("id"), 1)
  assert_eq(rows[0].text_by("name"), "heke1228")

  // A transaction bracket, rolled back through the seam.
  drv.begin()
  drv.execute("INSERT INTO moon_pg_async VALUES (?, ?)", [
    @moondb.Int(2),
    @moondb.Text("qwq"),
  ])
  |> ignore
  drv.rollback()
  assert_eq(drv.query("SELECT count(*) FROM moon_pg_async", [])[0].int64(0), 1L)
  drv.begin()
  drv.execute("INSERT INTO moon_pg_async VALUES (?, ?)", [
    @moondb.Int(3),
    @moondb.Text("hhh"),
  ])
  |> ignore
  drv.commit()
  assert_eq(drv.query("SELECT count(*) FROM moon_pg_async", [])[0].int64(0), 2L)
  drv.close()
}

///|
async test "integration: seam query_stream is the live cursor, not the materialised fallback" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let conn = pg_open()
  let drv : &@moondb.AsyncDriver = conn
  drv.execute("DROP TABLE IF EXISTS moon_pg_async_s", []) |> ignore
  drv.execute("CREATE TABLE moon_pg_async_s (id int)", []) |> ignore
  for i in 1..<5 {
    drv.execute("INSERT INTO moon_pg_async_s VALUES (?)", [@moondb.Int(i)])
    |> ignore
  }
  let cur = drv.query_stream("SELECT id FROM moon_pg_async_s ORDER BY id", [])
  assert_eq(cur.next().unwrap().int(0), 1)
  // The connection is mid-result: PgConn's streaming guard must still be set,
  // which is what tells the live cursor apart from the materialised fallback.
  let busy = try {
    conn.execute("SELECT 1", []) |> ignore
    false
  } catch {
    _ => true
  }
  assert_eq(busy, true)
  assert_eq(@moondb.drain_async(cur).length(), 3)
  // Drained to the end, so the connection is usable again.
  assert_eq(
    drv.query("SELECT count(*) FROM moon_pg_async_s", [])[0].int64(0),
    4L,
  )
  drv.close()
}
