// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The connection pool driving a real SQLite backend, not the MockDriver. The reuse
// proof is structural: each `SqliteDriver::open(":memory:")` is its own private
// database, so a table created on the first checkout is only visible on the second
// checkout if the pool handed back the SAME connection. If reuse were broken (a
// fresh :memory: opened instead), the follow-up query would raise "no such table".

///|
/// A pool of in-memory SQLite connections.
fn mem_pool(
  max_size? : Int = 4,
) -> @pool.Pool[@sqlite.SqliteDriver] raise @moondb.DbError {
  @pool.Pool::new(() => @sqlite.SqliteDriver::open(":memory:"), max_size~)
}

///|
test "pool over real SQLite: an idle connection is reused across acquire" {
  let pool = mem_pool(max_size=1)
  let c1 = pool.acquire()
  c1.execute("CREATE TABLE t (n INTEGER)", []) |> ignore
  c1.execute("INSERT INTO t (n) VALUES (?)", [@moondb.Int(7)]) |> ignore
  pool.release(c1)
  assert_eq(pool.idle_count(), 1)

  // Reused connection: the table and its row are still here (same :memory: db).
  let c2 = pool.acquire()
  assert_eq(pool.open_count(), 1) // never opened a second connection
  let rows = c2.query("SELECT n FROM t", [])
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].int(0), 7)
  pool.release(c2)
  pool.close_all()
  assert_eq(pool.open_count(), 0)
}

///|
test "pool over real SQLite: max_size caps concurrent checkouts" {
  let pool = mem_pool(max_size=1)
  let c1 = pool.acquire()
  let exhausted = try {
    pool.acquire() |> ignore
    false
  } catch {
    @moondb.QueryError(_) => true
    _ => false
  }
  assert_eq(exhausted, true)
  pool.release(c1)
  pool.close_all()
}

///|
test "pool over real SQLite: pre_ping evicts a connection closed underneath it" {
  let opened = [0]
  let pool = @pool.Pool::new(
    () => {
      opened[0] = opened[0] + 1
      @sqlite.SqliteDriver::open(":memory:")
    },
    max_size=2,
    pre_ping=true,
  )
  let c1 = pool.acquire()
  assert_eq(opened[0], 1)
  // The connection dies while checked out; the pool cannot know until it probes.
  c1.close()
  pool.release(c1)
  assert_eq(pool.idle_count(), 1)
  // pre_ping runs the driver's real `SELECT 1`, which fails on the closed handle, so
  // the dead connection is evicted and a fresh one is opened in its place.
  let c2 = pool.acquire()
  assert_eq(c2.is_closed(), false)
  assert_eq(opened[0], 2)
  // And it genuinely works: run a statement through the replacement.
  c2.execute("CREATE TABLE t (n INTEGER)", []) |> ignore
  assert_eq(c2.query("SELECT count(*) FROM t", [])[0].int(0), 0)
  pool.release(c2)
  pool.close_all()
}

///|
test "pool over real SQLite: with_conn runs a statement and returns the connection" {
  let pool = mem_pool()
  let n = pool.with_conn(db => {
    db.execute("CREATE TABLE k (v INTEGER)", []) |> ignore
    db.execute("INSERT INTO k (v) VALUES (?)", [@moondb.Int(1)]) |> ignore
    db.query("SELECT count(*) FROM k", [])[0].int(0)
  })
  assert_eq(n, 1)
  assert_eq(pool.idle_count(), 1)
  pool.close_all()
}
