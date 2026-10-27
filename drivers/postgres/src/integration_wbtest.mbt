// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Integration tests against a REAL PostgreSQL. Gated on the `MOON_PG_TEST`
// environment variable so a local checkout without a database is skipped
// cleanly; CI sets it (see .github/workflows/ci.yml, which stands up a
// `postgres:16` service). Connection parameters come from the standard `PG*`
// environment variables with localhost defaults.

///|
fn env_or(key : String, default : String) -> String {
  match @env.get_env_var(key) {
    Some(v) => if v == "" { default } else { v }
    None => default
  }
}

///|
fn env_port() -> Int32 {
  match parse_int(env_or("PGPORT", "5432")) {
    Some(p) => p
    None => 5432
  }
}

///|
async test "integration: connect, DDL, parameterised INSERT, SELECT round trip" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let conn = PgConn::connect(
    env_or("PGHOST", "127.0.0.1"),
    env_port(),
    env_or("PGUSER", "postgres"),
    env_or("PGPASSWORD", "postgres"),
    env_or("PGDATABASE", "test"),
  )
  conn.execute("DROP TABLE IF EXISTS moon_pg_t", []) |> ignore
  conn.execute("CREATE TABLE moon_pg_t (id int, name text)", []) |> ignore

  // parameterised INSERT: '?' is translated to '$1','$2' and bound out-of-band
  let r1 = conn.execute("INSERT INTO moon_pg_t VALUES (?, ?)", [
    @moondb.Int(1),
    @moondb.Text("alice"),
  ])
  assert_eq(r1.rows_affected, 1L)
  conn.execute("INSERT INTO moon_pg_t VALUES (?, ?)", [
    @moondb.Int(2),
    @moondb.Text("o'brien"),
  ])
  |> ignore

  // a NULL parameter must round-trip as SQL NULL, not the text "NULL"
  conn.execute("INSERT INTO moon_pg_t VALUES (?, ?)", [
    @moondb.Int(3),
    @moondb.Null,
  ])
  |> ignore
  let rows = conn.query("SELECT id, name FROM moon_pg_t ORDER BY id", [])
  assert_eq(rows.length(), 3)
  assert_eq(rows[0].int_by("id"), 1)
  assert_eq(rows[0].text_by("name"), "alice")
  assert_eq(rows[1].int(0), 2)
  assert_eq(rows[1].text(1), "o'brien") // injection-safe quote handling
  assert_eq(rows[2].is_null_by("name"), true)
  conn.close()
}

///|
async test "integration: query_stream yields rows incrementally and matches query" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let conn = pg_open()
  conn.execute("DROP TABLE IF EXISTS moon_pg_stream", []) |> ignore
  conn.execute("CREATE TABLE moon_pg_stream (id int, name text)", []) |> ignore
  for i in 1..<6 {
    conn.execute("INSERT INTO moon_pg_stream VALUES (?, ?)", [
      @moondb.Int(i),
      @moondb.Text("n" + i.to_string()),
    ])
    |> ignore
  }
  // Pull rows one at a time; they arrive in order and match a buffered query.
  let stream = conn.query_stream(
    "SELECT id, name FROM moon_pg_stream ORDER BY id",
    [],
  )
  let ids = []
  for row = stream.next(); row is Some(r); row = stream.next() {
    ids.push(r.int_by("id"))
  }
  assert_eq(ids, [1, 2, 3, 4, 5])
  // The connection is reusable once the stream drains.
  let again = conn.query("SELECT count(*) FROM moon_pg_stream", [])
  assert_eq(again[0].int64(0), 5L)
  // Early close: abandon a stream after one row, then run another statement.
  let partial = conn.query_stream("SELECT id FROM moon_pg_stream ORDER BY id", [])
  assert_eq(partial.next() is Some(_), true)
  partial.close()
  let reused = conn.query("SELECT count(*) FROM moon_pg_stream", [])
  assert_eq(reused[0].int64(0), 5L)
  // The pipeline guard: leaving a stream open (no drain, no close) must raise on
  // the next statement rather than silently desync the connection.
  let leaked = conn.query_stream("SELECT id FROM moon_pg_stream", [])
  assert_eq(leaked.next() is Some(_), true)
  let guarded = try {
    conn.query("SELECT 1", []) |> ignore
    false
  } catch {
    _ => true
  }
  assert_eq(guarded, true)
  leaked.close() // draining restores the connection for reuse
  assert_eq(conn.query("SELECT 1", [])[0].int(0), 1)
  conn.close()
}

///|
async test "integration: transactions commit and roll back" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let conn = PgConn::connect(
    env_or("PGHOST", "127.0.0.1"),
    env_port(),
    env_or("PGUSER", "postgres"),
    env_or("PGPASSWORD", "postgres"),
    env_or("PGDATABASE", "test"),
  )
  conn.execute("DROP TABLE IF EXISTS moon_pg_tx", []) |> ignore
  conn.execute("CREATE TABLE moon_pg_tx (n int)", []) |> ignore
  conn.begin()
  conn.execute("INSERT INTO moon_pg_tx VALUES (?)", [@moondb.Int(10)]) |> ignore
  conn.rollback()
  let after_rollback = conn.query("SELECT count(*) FROM moon_pg_tx", [])
  assert_eq(after_rollback[0].int64(0), 0L)
  conn.begin()
  conn.execute("INSERT INTO moon_pg_tx VALUES (?)", [@moondb.Int(20)]) |> ignore
  conn.commit()
  let after_commit = conn.query("SELECT n FROM moon_pg_tx", [])
  assert_eq(after_commit.length(), 1)
  assert_eq(after_commit[0].int(0), 20)
  conn.close()
}

///|
async fn pg_open() -> PgConn {
  PgConn::connect(
    env_or("PGHOST", "127.0.0.1"),
    env_port(),
    env_or("PGUSER", "postgres"),
    env_or("PGPASSWORD", "postgres"),
    env_or("PGDATABASE", "test"),
  )
}

///|
async test "integration: every Value type round-trips through the wire" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let conn = pg_open()
  conn.execute("DROP TABLE IF EXISTS moon_pg_types", []) |> ignore
  conn.execute(
    "CREATE TABLE moon_pg_types (b bool, i int, big bigint, d float8, t text, raw bytea)",
    [],
  )
  |> ignore
  let blob = b"\x00\x01\x7f\x80\xfe\xff"
  conn.execute("INSERT INTO moon_pg_types VALUES (?, ?, ?, ?, ?, ?)", [
    @moondb.Bool(true),
    @moondb.Int(-2147483648),
    @moondb.Int64(9223372036854775807L),
    @moondb.Double(-2.5),
    @moondb.Text(""),
    @moondb.Blob(blob),
  ])
  |> ignore
  // A NULL in every column must come back as SQL NULL, not a zero value.
  conn.execute("INSERT INTO moon_pg_types VALUES (?, ?, ?, ?, ?, ?)", [
    @moondb.Null,
    @moondb.Null,
    @moondb.Null,
    @moondb.Null,
    @moondb.Null,
    @moondb.Null,
  ])
  |> ignore
  let rows = conn.query(
    "SELECT b, i, big, d, t, raw FROM moon_pg_types ORDER BY i NULLS LAST",
    [],
  )
  assert_eq(rows.length(), 2)
  assert_eq(rows[0].bool_by("b"), true)
  assert_eq(rows[0].int_by("i"), -2147483648)
  assert_eq(rows[0].int64_by("big"), 9223372036854775807L)
  assert_eq(rows[0].double_by("d"), -2.5)
  assert_eq(rows[0].text_by("t"), "")
  assert_eq(rows[0].blob_by("raw"), blob)
  assert_eq(rows[1].is_null_by("b"), true)
  assert_eq(rows[1].is_null_by("raw"), true)
  conn.close()
}

///|
async test "integration: SAVEPOINT rolls back inner work while the outer tx commits" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let conn = pg_open()
  conn.execute("DROP TABLE IF EXISTS moon_pg_sp", []) |> ignore
  conn.execute("CREATE TABLE moon_pg_sp (n int)", []) |> ignore
  conn.begin()
  conn.execute("INSERT INTO moon_pg_sp VALUES (?)", [@moondb.Int(1)]) |> ignore
  conn.execute("SAVEPOINT sp1", []) |> ignore
  conn.execute("INSERT INTO moon_pg_sp VALUES (?)", [@moondb.Int(2)]) |> ignore
  conn.execute("ROLLBACK TO SAVEPOINT sp1", []) |> ignore
  conn.commit()
  let rows = conn.query("SELECT n FROM moon_pg_sp ORDER BY n", [])
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].int(0), 1)
  conn.close()
}

///|
async test "integration: the server error surface — syntax, missing table, unique" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let conn = pg_open()
  // A syntax error surfaces as a QueryError, not a silent success.
  let syntax = try {
    conn.query("SELCT 1", []) |> ignore
    false
  } catch {
    @moondb.QueryError(_) => true
    _ => false
  }
  assert_eq(syntax, true)
  // A missing table errors as QueryError. read_results already drains to
  // ReadyForQuery on error, so the connection stays usable for the next statement.
  let missing = try {
    conn.query("SELECT * FROM moon_pg_absent", []) |> ignore
    false
  } catch {
    @moondb.QueryError(_) => true
    _ => false
  }
  assert_eq(missing, true)
  // A UNIQUE violation on the duplicate insert errors.
  conn.execute("DROP TABLE IF EXISTS moon_pg_uq", []) |> ignore
  conn.execute("CREATE TABLE moon_pg_uq (k text UNIQUE)", []) |> ignore
  conn.execute("INSERT INTO moon_pg_uq VALUES (?)", [@moondb.Text("x")])
  |> ignore
  let dup = try {
    conn.execute("INSERT INTO moon_pg_uq VALUES (?)", [@moondb.Text("x")])
    |> ignore
    false
  } catch {
    @moondb.QueryError(_) => true
    _ => false
  }
  assert_eq(dup, true)
  conn.close()
}

///|
async test "integration: upsert ON CONFLICT DO UPDATE and RETURNING round-trip" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let conn = pg_open()
  conn.execute("DROP TABLE IF EXISTS moon_pg_kv", []) |> ignore
  conn.execute(
    "CREATE TABLE moon_pg_kv (k text PRIMARY KEY, v int, seen int)",
    [],
  )
  |> ignore

  // INSERT ... RETURNING hands the row back in one round trip. '?' translates to
  // '$1'..; the shape matches moonorm's insert(...).returning(...).
  let ins = conn.query(
    "INSERT INTO moon_pg_kv (k, v, seen) VALUES (?, ?, ?) RETURNING v",
    [@moondb.Text("hits"), @moondb.Int(1), @moondb.Int(1)],
  )
  assert_eq(ins.length(), 1)
  assert_eq(ins[0].int_by("v"), 1)

  // Upsert on the same key: excluded.v overwrites, a bound value bumps seen, and
  // RETURNING reads the merged row. This is the on_conflict/do_update path.
  let up = conn.query(
    "INSERT INTO moon_pg_kv (k, v, seen) VALUES (?, ?, ?) " +
    "ON CONFLICT (k) DO UPDATE SET v = excluded.v, seen = ? RETURNING v, seen",
    [@moondb.Text("hits"), @moondb.Int(9), @moondb.Int(0), @moondb.Int(2)],
  )
  assert_eq(up.length(), 1)
  assert_eq(up[0].int_by("v"), 9) // overwritten with the incoming value
  assert_eq(up[0].int_by("seen"), 2) // bumped by the bound parameter

  // Still exactly one row: the upsert merged rather than inserting a duplicate.
  let rows = conn.query("SELECT count(*) FROM moon_pg_kv", [])
  assert_eq(rows[0].int64(0), 1L)

  // DO NOTHING leaves the existing row untouched.
  conn.execute(
    "INSERT INTO moon_pg_kv (k, v, seen) VALUES (?, ?, ?) ON CONFLICT (k) DO NOTHING",
    [@moondb.Text("hits"), @moondb.Int(-1), @moondb.Int(-1)],
  )
  |> ignore
  let after = conn.query("SELECT v FROM moon_pg_kv WHERE k = ?", [
    @moondb.Text("hits"),
  ])
  assert_eq(after[0].int(0), 9) // unchanged by DO NOTHING
  conn.close()
}
