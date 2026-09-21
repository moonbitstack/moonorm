// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The completeness matrix against a REAL SQLite database: every Value TYPE round
// trip (NULL, Bool, Int, Int64/BIGINT at their 64-bit boundaries, Double, empty and
// UTF-8 Text, empty and large Blob), the statement kinds the smoke test skips
// (multi-row INSERT, JOIN, savepoints), and the error matrix (syntax error, UNIQUE
// violation, use-after-close). Each assertion runs bind -> step -> column against
// the vendored amalgamation, so a broken codec path turns it red.

///|
fn open_matrix() -> @moonsqlite.SqliteDriver raise @moondb.DbError {
  @moonsqlite.SqliteDriver::open(":memory:")
}

///|
test "sqlite matrix: every Value type binds and decodes back" {
  let db = open_matrix()
  db.execute("CREATE TABLE v (k TEXT, val)", []) |> ignore
  // A column with no declared affinity ("val") preserves each storage class as bound.
  let put = fn(k : String, x : @moondb.Value) -> Unit raise @moondb.DbError {
    db.execute("INSERT INTO v (k, val) VALUES (?, ?)", [@moondb.Text(k), x])
    |> ignore
  }
  let big_blob = Bytes::make(4096, b'\xA5')
  put("null", @moondb.Null)
  put("bool", @moondb.Bool(true))
  put("int", @moondb.Int(-2147483648))
  put("i64max", @moondb.Int64(9223372036854775807L))
  put("i64min", @moondb.Int64(-9223372036854775807L - 1L))
  put("dbl", @moondb.Double(-3.5))
  let utf8 = "héllo 世界 τιμή"
  put("empty", @moondb.Text(""))
  put("utf8", @moondb.Text(utf8))
  put("emptyblob", @moondb.Blob(b""))
  put("bigblob", @moondb.Blob(big_blob))
  let cell = fn(k : String) -> @moondb.Value raise @moondb.DbError {
    db.query("SELECT val FROM v WHERE k = ?", [@moondb.Text(k)])[0].get(0)
  }
  assert_eq(cell("null").is_null(), true)
  // SQLite has no native boolean; a bound Bool(true) is stored and read as 1.
  assert_eq(cell("bool") == @moondb.Int64(1L), true)
  assert_eq(cell("int") == @moondb.Int64(-2147483648L), true)
  assert_eq(cell("i64max") == @moondb.Int64(9223372036854775807L), true)
  assert_eq(cell("i64min") == @moondb.Int64(-9223372036854775807L - 1L), true)
  assert_eq(cell("dbl") == @moondb.Double(-3.5), true)
  assert_eq(cell("empty") == @moondb.Text(""), true)
  assert_eq(cell("utf8") == @moondb.Text(utf8), true)
  assert_eq(cell("emptyblob") == @moondb.Blob(b""), true)
  let out = cell("bigblob")
  assert_eq(out == @moondb.Blob(big_blob), true)
  db.close()
}

///|
test "sqlite matrix: multi-row INSERT persists every tuple in one statement" {
  let db = open_matrix()
  db.execute("CREATE TABLE nums (n INTEGER)", []) |> ignore
  let r = db.execute("INSERT INTO nums (n) VALUES (?), (?), (?)", [
    @moondb.Int(1),
    @moondb.Int(2),
    @moondb.Int(3),
  ])
  assert_eq(r.rows_affected, 3L)
  let rows = db.query("SELECT n FROM nums ORDER BY n ASC", [])
  assert_eq(rows.length(), 3)
  assert_eq(rows[0].int(0), 1)
  assert_eq(rows[2].int(0), 3)
  db.close()
}

///|
test "sqlite matrix: an inner JOIN resolves rows across two tables" {
  let db = open_matrix()
  db.exec_script(
    "CREATE TABLE team (id INTEGER PRIMARY KEY, name TEXT);" +
    "CREATE TABLE hero (id INTEGER PRIMARY KEY, name TEXT, team_id INTEGER);" +
    "INSERT INTO team VALUES (1, 'avengers');" +
    "INSERT INTO hero VALUES (1, 'ironman', 1);" +
    "INSERT INTO hero VALUES (2, 'wolverine', 2);",
  )
  let rows = db.query(
    "SELECT hero.name AS h, team.name AS t FROM hero JOIN team ON hero.team_id = team.id ORDER BY hero.id",
    [],
  )
  assert_eq(rows.length(), 1) // wolverine's team_id=2 has no matching team
  assert_eq(rows[0].text_by("h"), "ironman")
  assert_eq(rows[0].text_by("t"), "avengers")
  db.close()
}

///|
test "sqlite matrix: SAVEPOINT / ROLLBACK TO undoes inner work, RELEASE keeps it" {
  let db = open_matrix()
  db.execute("CREATE TABLE s (n INTEGER)", []) |> ignore
  db.begin()
  db.execute("INSERT INTO s VALUES (1)", []) |> ignore
  db.execute("SAVEPOINT sp1", []) |> ignore
  db.execute("INSERT INTO s VALUES (2)", []) |> ignore
  // Roll back to the savepoint: only the second insert vanishes.
  db.execute("ROLLBACK TO SAVEPOINT sp1", []) |> ignore
  assert_eq(db.query("SELECT n FROM s", []).length(), 1)
  // A fresh savepoint that is released merges into the outer transaction.
  db.execute("SAVEPOINT sp2", []) |> ignore
  db.execute("INSERT INTO s VALUES (3)", []) |> ignore
  db.execute("RELEASE SAVEPOINT sp2", []) |> ignore
  db.commit()
  let rows = db.query("SELECT n FROM s ORDER BY n", [])
  assert_eq(rows.length(), 2)
  assert_eq(rows[0].int(0), 1)
  assert_eq(rows[1].int(0), 3)
  db.close()
}

///|
test "sqlite matrix: a WITH CTE and an IN-subquery execute with bound params" {
  let db = open_matrix()
  db.exec_script(
    "CREATE TABLE orders (user_id INTEGER, total INTEGER);" +
    "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, active INTEGER);" +
    "INSERT INTO users VALUES (1, 'ann', 1), (2, 'bob', 1), (3, 'cid', 0);" +
    "INSERT INTO orders VALUES (1, 500), (2, 20), (1, 300);",
  )
  // The exact SQL shape moonorm's builder emits for
  //   select("users").with_cte("big", select("orders")...).where_in("id", ...)
  // — run here against real SQLite to prove the dialect and the ? binding are valid.
  let rows = db.query(
    "WITH big_spenders AS (SELECT user_id FROM orders WHERE total > ?) " +
    "SELECT id, name FROM users WHERE active = ? AND id IN (SELECT user_id FROM big_spenders) ORDER BY id",
    [@moondb.Int(100), @moondb.Int(1)],
  )
  // Only user 1 (ann) has an order over 100 and is active.
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].int_by("id"), 1)
  assert_eq(rows[0].text_by("name"), "ann")
  db.close()
}

///|
test "sqlite matrix: INSERT ... RETURNING hands back the server-assigned id" {
  let db = open_matrix()
  db.execute("CREATE TABLE u (id INTEGER PRIMARY KEY, name TEXT)", []) |> ignore
  // The exact shape moonorm emits for insert(...).returning("id") — run on real
  // SQLite so the id comes from the engine, not a guess. Two inserts must return
  // the two distinct rowids the engine assigned.
  let r1 = db.query("INSERT INTO u (name) VALUES (?) RETURNING id", [
    @moondb.Text("ann"),
  ])
  assert_eq(r1.length(), 1)
  assert_eq(r1[0].int_by("id"), 1)
  let r2 = db.query("INSERT INTO u (name) VALUES (?) RETURNING id", [
    @moondb.Text("bob"),
  ])
  assert_eq(r2[0].int_by("id"), 2)
  // RETURNING * gives every column of the affected row back.
  let r3 = db.query("INSERT INTO u (name) VALUES (?) RETURNING *", [
    @moondb.Text("cid"),
  ])
  assert_eq(r3[0].int_by("id"), 3)
  assert_eq(r3[0].text_by("name"), "cid")
  db.close()
}

///|
test "sqlite matrix: upsert ON CONFLICT DO UPDATE overwrites in place" {
  let db = open_matrix()
  db.execute("CREATE TABLE kv (k TEXT PRIMARY KEY, v INTEGER)", []) |> ignore
  // moonorm's insert("kv").set(...).on_conflict(["k"]).do_update_excluded("v").
  let upsert = fn(k : String, v : Int) -> Unit raise @moondb.DbError {
    db.execute(
      "INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT (k) DO UPDATE SET v = excluded.v",
      [@moondb.Text(k), @moondb.Int(v)],
    )
    |> ignore
  }
  upsert("hits", 1)
  upsert("hits", 5) // same key: updates in place rather than raising UNIQUE
  let rows = db.query("SELECT k, v FROM kv", [])
  assert_eq(rows.length(), 1) // still one row, not two
  assert_eq(rows[0].int_by("v"), 5) // overwritten with the incoming value
  // A bound DO UPDATE value, and RETURNING the merged row in one round trip.
  let r = db.query(
    "INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT (k) DO UPDATE SET v = ? RETURNING v",
    [@moondb.Text("hits"), @moondb.Int(0), @moondb.Int(99)],
  )
  assert_eq(r[0].int_by("v"), 99)
  db.close()
}

///|
test "sqlite matrix: upsert ON CONFLICT DO NOTHING keeps the existing row" {
  let db = open_matrix()
  db.execute("CREATE TABLE t (k TEXT PRIMARY KEY, v INTEGER)", []) |> ignore
  db.execute("INSERT INTO t (k, v) VALUES (?, ?)", [
    @moondb.Text("a"),
    @moondb.Int(1),
  ])
  |> ignore
  db.execute("INSERT INTO t (k, v) VALUES (?, ?) ON CONFLICT (k) DO NOTHING", [
    @moondb.Text("a"),
    @moondb.Int(2),
  ])
  |> ignore
  let rows = db.query("SELECT v FROM t", [])
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].int(0), 1) // untouched by the DO NOTHING insert
  db.close()
}

///|
test "sqlite matrix: window ROW_NUMBER partitions and ranks rows" {
  let db = open_matrix()
  db.exec_script(
    "CREATE TABLE emp (name TEXT, dept TEXT, salary INTEGER);" +
    "INSERT INTO emp VALUES ('a','eng',100),('b','eng',120),('c','sales',90),('d','sales',90);",
  )
  // moonorm's select("emp").window("ROW_NUMBER()", partition_by=["dept"],
  //   order_by=[("salary", Desc)], as_="rn") — run on real SQLite.
  let rows = db.query(
    "SELECT name, ROW_NUMBER() OVER (PARTITION BY dept ORDER BY salary DESC) AS rn FROM emp ORDER BY dept, rn",
    [],
  )
  assert_eq(rows.length(), 4)
  // eng: b(120) is rank 1, a(100) rank 2.
  assert_eq(rows[0].text_by("name"), "b")
  assert_eq(rows[0].int_by("rn"), 1)
  assert_eq(rows[1].text_by("name"), "a")
  assert_eq(rows[1].int_by("rn"), 2)
  // sales: two at rank 1 and 2 by row order.
  assert_eq(rows[2].int_by("rn"), 1)
  assert_eq(rows[3].int_by("rn"), 2)
  db.close()
}

///|
fn sqlite_error_kind(f : () -> Unit raise @moondb.DbError) -> String {
  try {
    f()
    "no-error"
  } catch {
    @moondb.QueryError(_) => "query"
    @moondb.Closed => "closed"
    _ => "other"
  }
}

///|
test "sqlite matrix: the error surface — syntax, constraint, use-after-close" {
  let db = open_matrix()
  db.execute("CREATE TABLE u (id INTEGER PRIMARY KEY, name TEXT UNIQUE)", [])
  |> ignore
  // A malformed statement is a QueryError carrying SQLite's message.
  assert_eq(
    sqlite_error_kind(() => db.query("SELCT nope FROM u", []) |> ignore),
    "query",
  )
  // A UNIQUE violation on the second insert surfaces as a QueryError.
  db.execute("INSERT INTO u (name) VALUES (?)", [@moondb.Text("dup")]) |> ignore
  assert_eq(
    sqlite_error_kind(() => {
      db.execute("INSERT INTO u (name) VALUES (?)", [@moondb.Text("dup")])
      |> ignore
    }),
    "query",
  )
  // After close, every statement is a clean Closed, never a dangling-pointer call.
  db.close()
  assert_eq(db.is_closed(), true)
  db.close() // idempotent
  assert_eq(
    sqlite_error_kind(() => db.query("SELECT 1", []) |> ignore),
    "closed",
  )
  assert_eq(
    sqlite_error_kind(() => db.execute("SELECT 1", []) |> ignore),
    "closed",
  )
  assert_eq(sqlite_error_kind(() => db.begin()), "closed")
}
