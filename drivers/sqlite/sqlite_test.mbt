// Real end-to-end integration tests: these open an actual SQLite database, run
// statements through the native driver against the `@moondb.Driver` contract, and
// read rows back. If the driver does not truly execute — if the C bind/step/column
// path is broken — these assertions fail (mutation-verified: breaking any of prepare,
// bind, step, or column decoding turns them red).

///|
/// Open an in-memory database or abort the test with SQLite's message.
fn open_mem() -> @moonsqlite.SqliteDriver raise @moondb.DbError {
  @moonsqlite.SqliteDriver::open(":memory:")
}

///|
test "sqlite: CREATE / INSERT (bound params) / SELECT round-trips real rows" {
  let db = open_mem()
  db.execute(
    "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)",
    [],
  )
  |> ignore
  let r1 = db.execute("INSERT INTO users (name, age) VALUES (?, ?)", [
    @moondb.Text("alice"),
    @moondb.Int(30),
  ])
  assert_eq(r1.rows_affected, 1L)
  assert_eq(r1.last_insert_id, 1L)
  db.execute("INSERT INTO users (name, age) VALUES (?, ?)", [
    @moondb.Text("bob"),
    @moondb.Int(17),
  ])
  |> ignore
  // WHERE / ORDER BY reach the real engine; the bound 18 filters bob out.
  let rows = db.query(
    "SELECT name, age FROM users WHERE age > ? ORDER BY name ASC",
    [@moondb.Int(18)],
  )
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].text(0), "alice")
  assert_eq(rows[0].int(1), 30)
  assert_eq(rows[0].text_by("name"), "alice")
  db.close()
}

///|
test "sqlite: an injection string is bound, never executed" {
  let db = open_mem()
  db.execute("CREATE TABLE t (name TEXT)", []) |> ignore
  db.execute("INSERT INTO t (name) VALUES (?)", [@moondb.Text("safe")])
  |> ignore
  let evil = "'; DROP TABLE t; --"
  db.execute("INSERT INTO t (name) VALUES (?)", [@moondb.Text(evil)]) |> ignore
  // The table survives (DROP never ran) and holds both literal strings.
  let rows = db.query("SELECT name FROM t ORDER BY name ASC", [])
  assert_eq(rows.length(), 2)
  assert_eq(rows[0].text(0), evil)
  assert_eq(rows[1].text(0), "safe")
  db.close()
}

///|
test "sqlite: UPDATE and DELETE report real affected-row counts" {
  let db = open_mem()
  db.execute("CREATE TABLE p (id INTEGER, qty INTEGER)", []) |> ignore
  for i = 1; i <= 3; i = i + 1 {
    db.execute("INSERT INTO p (id, qty) VALUES (?, ?)", [
      @moondb.Int(i),
      @moondb.Int(i),
    ])
    |> ignore
  }
  let up = db.execute("UPDATE p SET qty = ? WHERE id > ?", [
    @moondb.Int(99),
    @moondb.Int(1),
  ])
  assert_eq(up.rows_affected, 2L)
  let del = db.execute("DELETE FROM p WHERE qty = ?", [@moondb.Int(99)])
  assert_eq(del.rows_affected, 2L)
  let rows = db.query("SELECT id FROM p", [])
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].int(0), 1)
  db.close()
}

///|
test "sqlite: transaction rollback undoes its work, commit keeps it" {
  let db = open_mem()
  db.execute("CREATE TABLE acc (n INTEGER)", []) |> ignore
  // Rolled-back work must vanish.
  db.begin()
  db.execute("INSERT INTO acc (n) VALUES (?)", [@moondb.Int(1)]) |> ignore
  db.rollback()
  assert_eq(db.query("SELECT n FROM acc", []).length(), 0)
  // Committed work must persist.
  db.begin()
  db.execute("INSERT INTO acc (n) VALUES (?)", [@moondb.Int(2)]) |> ignore
  db.commit()
  let rows = db.query("SELECT n FROM acc", [])
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].int(0), 2)
  db.close()
}

///|
test "sqlite: Double and Blob storage classes round-trip through bind + decode" {
  let db = open_mem()
  db.execute("CREATE TABLE m (k TEXT, r REAL, b BLOB)", []) |> ignore
  let blob = b"\x00\x01\xfe\xff"
  db.execute("INSERT INTO m (k, r, b) VALUES (?, ?, ?)", [
    @moondb.Text("pi"),
    @moondb.Double(3.5),
    @moondb.Blob(blob),
  ])
  |> ignore
  let rows = db.query("SELECT k, r, b FROM m", [])
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].text(0), "pi")
  assert_eq(rows[0].double(1), 3.5)
  assert_eq(rows[0].blob(2), blob)
  db.close()
}

///|
test "sqlite: exec_script runs a multi-statement schema in one call" {
  let db = open_mem()
  db.exec_script(
    "CREATE TABLE s (v INTEGER); INSERT INTO s VALUES (7); INSERT INTO s VALUES (8);",
  )
  let rows = db.query("SELECT v FROM s ORDER BY v ASC", [])
  assert_eq(rows.length(), 2)
  assert_eq(rows[0].int(0), 7)
  assert_eq(rows[1].int(0), 8)
  db.close()
}

///|
test "sqlite: a bad statement surfaces SQLite's message as QueryError" {
  let db = open_mem()
  // The no-such-table error must propagate as a moondb QueryError, not be swallowed.
  let caught = try {
    db.query("SELECT * FROM does_not_exist", []) |> ignore
    None
  } catch {
    @moondb.QueryError(m) => Some(m)
    other => raise other
  }
  match caught {
    Some(m) => assert_eq(m.contains("does_not_exist"), true)
    None => abort("expected a QueryError for a missing table")
  }
  db.close()
}

///|
test "sqlite query_stream steps rows lazily and matches query" {
  let db = open_mem()
  db.execute("CREATE TABLE s (id INTEGER, name TEXT)", []) |> ignore
  for i in 1..<6 {
    db.execute("INSERT INTO s VALUES (?, ?)", [
      @moondb.Int(i),
      @moondb.Text("n" + i.to_string()),
    ])
    |> ignore
  }
  // Draining the cursor yields exactly what a buffered query would.
  let streamed = @moondb.drain(
    db.query_stream("SELECT id, name FROM s ORDER BY id", []),
  )
  let buffered = db.query("SELECT id, name FROM s ORDER BY id", [])
  assert_eq(streamed.length(), 5)
  assert_eq(streamed.length(), buffered.length())
  let mut same = true
  for i in 0..<streamed.length() {
    if !(streamed[i].values == buffered[i].values) {
      same = false
    }
  }
  assert_eq(same, true)
  // Early close mid-stream, then the connection runs the next statement.
  let cur = db.query_stream("SELECT id FROM s ORDER BY id", [])
  assert_eq(cur.next() is Some(_), true)
  cur.close()
  assert_eq(db.query("SELECT count(*) FROM s", [])[0].int64(0), 5L)
  db.close()
}
