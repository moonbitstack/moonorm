// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Read an environment variable, falling back to `default`.
fn env_or(name : String, default : String) -> String {
  match @env.get_env_var(name) {
    Some(v) => v
    None => default
  }
}

///|
/// End-to-end roundtrip against a real MySQL server. It is gated on `MYSQL_TEST`
/// so the local `moon test` (which usually has no database) skips it, while CI —
/// which starts a MySQL 8 service and exports `MYSQL_TEST=1` — runs it for real.
/// Connection details come from `MYSQL_HOST` / `MYSQL_PORT` / `MYSQL_USER` /
/// `MYSQL_PASSWORD` / `MYSQL_DB`, each with a sensible default.
///
/// It drives the whole text protocol through the synchronous `@moondb.Driver`
/// surface: connect + mysql_native_password auth, a DDL `execute`, parameter-
/// bound `execute`s (integers, UTF-8 text, an embedded quote — the escaping
/// path), and a `query` whose rows are asserted cell by cell. Breaking the
/// row-packet decoder turns the row assertions red (mutation check).
test "integration: real MySQL CREATE/INSERT/SELECT roundtrip" {
  guard @env.get_env_var("MYSQL_TEST") is Some(_) else { return }
  let host = env_or("MYSQL_HOST", "127.0.0.1")
  let port = match @env.get_env_var("MYSQL_PORT") {
    Some(p) => @string.parse_int(p[:]) catch { _ => 3306 }
    None => 3306
  }
  let db = @client.MysqlDriver::new(
    host~,
    port~,
    user=env_or("MYSQL_USER", "root"),
    password=env_or("MYSQL_PASSWORD", "root"),
    database=env_or("MYSQL_DB", "test"),
  )
  let _ = db.execute("DROP TABLE IF EXISTS t_moon_mysql", [])
  let _ = db.execute(
    "CREATE TABLE t_moon_mysql (id INT PRIMARY KEY, name TEXT)",
    [],
  )
  let r1 = db.execute("INSERT INTO t_moon_mysql VALUES (?, ?)", [
    @moondb.Int(1),
    @moondb.Text("a"),
  ])
  assert_eq(r1.rows_affected, 1L)
  // UTF-8 text and an embedded single quote exercise the escaping path.
  let _ = db.execute("INSERT INTO t_moon_mysql VALUES (?, ?)", [
    @moondb.Int(2),
    @moondb.Text("béta"),
  ])
  let _ = db.execute("INSERT INTO t_moon_mysql VALUES (?, ?)", [
    @moondb.Int(3),
    @moondb.Text("a'b"),
  ])
  let rows = db.query("SELECT id, name FROM t_moon_mysql ORDER BY id", [])
  assert_eq(rows.length(), 3)
  assert_eq(rows[0].int_by("id"), 1)
  assert_eq(rows[0].text_by("name"), "a")
  assert_eq(rows[1].int_by("id"), 2)
  assert_eq(rows[1].text_by("name"), "béta")
  assert_eq(rows[2].text_by("name"), "a'b")
  // A query against a missing table surfaces the server's ERR as a DbError.
  let missing = try {
    let _ = db.query("SELECT * FROM no_such_table_here", [])
    "no-error"
  } catch {
    _ => "errored"
  }
  assert_eq(missing, "errored")
}

///|
fn mysql_driver() -> @client.MysqlDriver {
  @client.MysqlDriver::new(
    host=env_or("MYSQL_HOST", "127.0.0.1"),
    port=match @env.get_env_var("MYSQL_PORT") {
      Some(p) => @string.parse_int(p[:]) catch { _ => 3306 }
      None => 3306
    },
    user=env_or("MYSQL_USER", "root"),
    password=env_or("MYSQL_PASSWORD", "root"),
    database=env_or("MYSQL_DB", "test"),
  )
}

///|
/// Every Value type through a real round trip: a distinct MySQL column type per
/// case, then the decoded cell asserted. Breaking the text-row decoder or a
/// literal renderer turns a row assertion red.
test "integration: every Value type round-trips through MySQL" {
  guard @env.get_env_var("MYSQL_TEST") is Some(_) else { return }
  let db = mysql_driver()
  let _ = db.execute("DROP TABLE IF EXISTS t_moon_types", [])
  let _ = db.execute(
    "CREATE TABLE t_moon_types (id INT PRIMARY KEY, i INT, big BIGINT, d DOUBLE, t TEXT, e TEXT, raw BLOB, n INT)",
    [],
  )
  let blob = b"\x00\x01\x7f\x80\xfe\xff"
  let _ = db.execute(
    "INSERT INTO t_moon_types VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    [
      @moondb.Int(1),
      @moondb.Int(-2147483648),
      @moondb.Int64(9223372036854775807L),
      @moondb.Double(-2.5),
      @moondb.Text("héllo 世界"),
      @moondb.Text(""),
      @moondb.Blob(blob),
      @moondb.Null,
    ],
  )
  let rows = db.query(
    "SELECT i, big, d, t, e, raw, n FROM t_moon_types WHERE id = ?",
    [@moondb.Int(1)],
  )
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].int_by("i"), -2147483648)
  assert_eq(rows[0].int64_by("big"), 9223372036854775807L)
  assert_eq(rows[0].double_by("d"), -2.5)
  assert_eq(rows[0].text_by("t"), "héllo 世界")
  assert_eq(rows[0].text_by("e"), "")
  assert_eq(rows[0].blob_by("raw"), blob)
  assert_eq(rows[0].is_null_by("n"), true)
}

///|
/// The server error surface: a syntax error and a duplicate-primary-key
/// violation must both come back as a DbError, not a silent success.
test "integration: MySQL error surface — syntax and duplicate key" {
  guard @env.get_env_var("MYSQL_TEST") is Some(_) else { return }
  let db = mysql_driver()
  let syntax = try {
    let _ = db.query("SELCT 1", [])
    false
  } catch {
    _ => true
  }
  assert_eq(syntax, true)
  let _ = db.execute("DROP TABLE IF EXISTS t_moon_uq", [])
  let _ = db.execute("CREATE TABLE t_moon_uq (id INT PRIMARY KEY)", [])
  let _ = db.execute("INSERT INTO t_moon_uq VALUES (?)", [@moondb.Int(1)])
  let dup = try {
    let _ = db.execute("INSERT INTO t_moon_uq VALUES (?)", [@moondb.Int(1)])
    false
  } catch {
    _ => true
  }
  assert_eq(dup, true)
}

///|
/// Real transactions over the async @client.MysqlConn (the sync Driver adapter is
/// autocommit-only). A rolled-back INSERT must vanish; a committed one persists.
async test "integration: MySQL transactions commit and roll back" {
  guard @env.get_env_var("MYSQL_TEST") is Some(_) else { return }
  let port = match @env.get_env_var("MYSQL_PORT") {
    Some(p) => @string.parse_int(p[:]) catch { _ => 3306 }
    None => 3306
  }
  let conn = @client.MysqlConn::connect(
    env_or("MYSQL_HOST", "127.0.0.1"),
    port,
    env_or("MYSQL_USER", "root"),
    env_or("MYSQL_PASSWORD", "root"),
    env_or("MYSQL_DB", "test"),
  )
  let _ = conn.execute("DROP TABLE IF EXISTS t_moon_tx", [])
  // InnoDB is required for transactional DDL rollback semantics.
  let _ = conn.execute("CREATE TABLE t_moon_tx (n INT) ENGINE=InnoDB", [])
  conn.begin()
  let _ = conn.execute("INSERT INTO t_moon_tx VALUES (?)", [@moondb.Int(1)])
  conn.rollback()
  let after_rollback = conn.query("SELECT COUNT(*) FROM t_moon_tx", [])
  assert_eq(after_rollback[0].int64(0), 0L)
  conn.begin()
  let _ = conn.execute("INSERT INTO t_moon_tx VALUES (?)", [@moondb.Int(2)])
  conn.commit()
  let after_commit = conn.query("SELECT n FROM t_moon_tx", [])
  assert_eq(after_commit.length(), 1)
  assert_eq(after_commit[0].int(0), 2)
  conn.close()
}

///|
/// Streaming: query_stream reads rows off the wire one at a time. They must arrive
/// in order and match a buffered query, and the connection must stay usable after
/// the stream drains or is closed early.
async test "integration: MySQL query_stream yields rows incrementally and matches query" {
  guard @env.get_env_var("MYSQL_TEST") is Some(_) else { return }
  let port = match @env.get_env_var("MYSQL_PORT") {
    Some(p) => @string.parse_int(p[:]) catch { _ => 3306 }
    None => 3306
  }
  let conn = @client.MysqlConn::connect(
    env_or("MYSQL_HOST", "127.0.0.1"),
    port,
    env_or("MYSQL_USER", "root"),
    env_or("MYSQL_PASSWORD", "root"),
    env_or("MYSQL_DB", "test"),
  )
  let _ = conn.execute("DROP TABLE IF EXISTS t_moon_stream", [])
  let _ = conn.execute(
    "CREATE TABLE t_moon_stream (id INT, name TEXT) ENGINE=InnoDB",
    [],
  )
  for i in 1..<6 {
    let _ = conn.execute("INSERT INTO t_moon_stream VALUES (?, ?)", [
      @moondb.Int(i),
      @moondb.Text("n" + i.to_string()),
    ])
  }
  let stream = conn.query_stream(
    "SELECT id, name FROM t_moon_stream ORDER BY id",
    [],
  )
  let ids = []
  for row = stream.next(); row is Some(r); row = stream.next() {
    ids.push(r.int_by("id"))
  }
  assert_eq(ids, [1, 2, 3, 4, 5])
  let again = conn.query("SELECT COUNT(*) FROM t_moon_stream", [])
  assert_eq(again[0].int64(0), 5L)
  // Early close then reuse the connection.
  let partial = conn.query_stream("SELECT id FROM t_moon_stream ORDER BY id", [])
  assert_eq(partial.next() is Some(_), true)
  partial.close()
  let reused = conn.query("SELECT COUNT(*) FROM t_moon_stream", [])
  assert_eq(reused[0].int64(0), 5L)
  // The pipeline guard: an outstanding stream must raise on the next command
  // rather than silently desync the connection.
  let leaked = conn.query_stream("SELECT id FROM t_moon_stream ORDER BY id", [])
  assert_eq(leaked.next() is Some(_), true)
  let guarded = try {
    conn.query("SELECT 1", []) |> ignore
    false
  } catch {
    _ => true
  }
  assert_eq(guarded, true)
  leaked.close()
  assert_eq(conn.query("SELECT 1", [])[0].int(0), 1)
  conn.close()
}
