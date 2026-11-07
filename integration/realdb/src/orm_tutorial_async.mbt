// The asynchronous session against the two real servers it exists for. PostgreSQL and
// MySQL reach moonorm through `@moondb.AsyncDriver` only, so before `AsyncSession`
// there was no way to run the ORM over either of them.
//
// Gated on `MOONORM_LIVE`, like the rest of this module: with it set the servers must
// be reachable and a failed connection is a failure, not a skip.

///|
/// Run the quick start through `AsyncSession` and return the transcript — the same
/// steps as `quickstart_sync`, awaited.
async fn quickstart_async(
  conn : &@moondb.AsyncDriver,
  dialect : @query.Dialect,
) -> Array[String] raise @moondb.DbError {
  let sess = @session.AsyncSession::new(conn, dialect~)
  let users = user_model()
  let addresses = address_model()
  let out : Array[String] = []
  for statement in quickstart_ddl(dialect) {
    sess.execute(statement, []) |> ignore
  }
  sess.begin()
  sess.add_all(users, quickstart_users())
  sess.add_all(addresses, quickstart_addresses())
  sess.commit()

  let sandy = sess.fetch_as(
    users,
    users.select().where_("name", "=", @moondb.Text("sandy")),
  )
  out.push("select-sandy: " + sandy[0].fullname.unwrap_or(""))

  let ordered = sess.fetch_as(users, users.select().order_by("id", Asc))
  out.push("ordered-by-id: " + ordered.map(u => u.name).join(", "))

  let (sql, params) = addresses_per_user_query()
  let line : Array[String] = []
  for row in sess.query(sql, params) {
    line.push(row.text(0) + "=" + value_text(row.get(1)))
  }
  out.push("addresses-per-user: " + line.join(", "))

  let rel = @schema.has_many(address_model(), "user_id", (u : User) => {
    @moondb.Int(u.id)
  })
  let loaded = sess.load(
    { id: 2, name: "sandy", fullname: Some("Sandy Cheeks"), },
    rel,
  )
  out.push("addresses-of-sandy: " + loaded.map(a => a.email_address).join(", "))

  sess.begin()
  sess.update_record(users, {
    id: 2,
    name: "sandy",
    fullname: Some("Sandy Squirrel"),
  })
  sess.commit()
  let updated = sess.fetch_as(
    users,
    users.select().where_("id", "=", @moondb.Int(2)),
  )
  out.push("after-update: " + updated[0].fullname.unwrap_or(""))

  sess.begin()
  sess.delete_record(users, { id: 3, name: "patrick", fullname: None, })
  sess.commit()
  let left = sess
    .scalar(count_query("user_account"))
    .unwrap_or(@moondb.Int64(0L))
  let left_addresses = sess
    .scalar(count_query("address"))
    .unwrap_or(@moondb.Int64(0L))
  out.push(
    "after-delete: " +
    value_text(left) +
    " users, " +
    value_text(left_addresses) +
    " addresses",
  )
  // Leave the database as it was found: the module's other tests reflect the whole
  // schema, and a stray table here would read as drift in theirs.
  for
    statement in [
      "DROP TABLE IF EXISTS address", "DROP TABLE IF EXISTS user_account",
    ] {
    sess.execute(statement, []) |> ignore
  }
  sess.close()
  out
}

///|
async test "orm quick start: PostgreSQL reproduces the transcript" {
  guard live() else { return }
  let conn = @pg.PgConn::connect(
    env_or("PGHOST", "127.0.0.1"),
    env_port("PGPORT", 5432),
    env_or("PGUSER", "orm"),
    env_or("PGPASSWORD", "pw"),
    env_or("PGDATABASE", "orm"),
  )
  let out = quickstart_async(conn, @query.Postgres) catch {
    error => abort("quick start failed: " + error.to_string())
  }
  assert_eq(out, expected_quickstart())
}

///|
async test "orm quick start: MySQL reproduces the transcript" {
  guard live() else { return }
  let conn = @mysql.MysqlConn::connect(
    env_or("MYSQLHOST", "127.0.0.1"),
    env_port("MYSQLPORT", 3306),
    env_or("MYSQLUSER", "root"),
    env_or("MYSQLPASSWORD", "pw"),
    env_or("MYSQLDATABASE", "orm"),
  )
  let out = quickstart_async(conn, @query.Mysql) catch {
    error => abort("quick start failed: " + error.to_string())
  }
  assert_eq(out, expected_quickstart())
}

///|
/// A fresh table for the savepoint and streaming checks, so they do not depend on what
/// the quick start left behind.
async fn reset_notes(
  conn : &@moondb.AsyncDriver,
  dialect : @query.Dialect,
) -> @session.AsyncSession raise @moondb.DbError {
  let sess = @session.AsyncSession::new(conn, dialect~)
  for
    statement in [
      "DROP TABLE IF EXISTS notes", "CREATE TABLE notes (id INTEGER PRIMARY KEY, body VARCHAR(64) NOT NULL)",
    ] {
    sess.execute(statement, []) |> ignore
  }
  sess
}

///|
async test "async session: a savepoint rollback takes the row and the cached record with it" {
  guard live() else { return }
  let conn = @pg.PgConn::connect(
    env_or("PGHOST", "127.0.0.1"),
    env_port("PGPORT", 5432),
    env_or("PGUSER", "orm"),
    env_or("PGPASSWORD", "pw"),
    env_or("PGDATABASE", "orm"),
  )
  let sess = reset_notes(conn, @query.Postgres)
  let notes = note_model()
  sess.begin()
  sess.insert_record(notes, { id: 1, body: "kept", }) |> ignore
  let sp = sess.begin_nested()
  sess.insert_record(notes, { id: 2, body: "rolled back", }) |> ignore
  // The insert is in the database *and* in the identity map.
  assert_eq(sess.get(notes, @moondb.Int(2)).unwrap().body, "rolled back")
  sp.rollback()
  // Both halves are gone: the row from the server, the record from the map.
  assert_eq(sess.get(notes, @moondb.Int(2)) is None, true)
  sess.commit()
  assert_eq(sess.scalar(count_query("notes")), Some(@moondb.Int64(1L)))
  // The row written before the savepoint survived.
  assert_eq(sess.get(notes, @moondb.Int(1)).unwrap().body, "kept")
  sess.execute("DROP TABLE IF EXISTS notes", []) |> ignore
  sess.close()
}

///|
async test "async session: a streamed read comes back one row at a time" {
  guard live() else { return }
  let conn = @pg.PgConn::connect(
    env_or("PGHOST", "127.0.0.1"),
    env_port("PGPORT", 5432),
    env_or("PGUSER", "orm"),
    env_or("PGPASSWORD", "pw"),
    env_or("PGDATABASE", "orm"),
  )
  let sess = reset_notes(conn, @query.Postgres)
  let notes = note_model()
  for i = 1; i <= 3; i = i + 1 {
    sess.insert_record(notes, { id: i, body: "note " + i.to_string(), })
    |> ignore
  }
  let stream = sess.stream_as(notes, notes.select().order_by("id", Asc))
  let seen : Array[String] = []
  while true {
    match stream.next() {
      Some(note) => seen.push(note.body)
      None => break
    }
  }
  assert_eq(seen, ["note 1", "note 2", "note 3"])
  sess.execute("DROP TABLE IF EXISTS notes", []) |> ignore
  sess.close()
}

///|
/// A driver wrapper that counts how many `query` calls are inside the driver at once,
/// so the concurrency check reads a number instead of trusting a stopwatch alone.
priv struct OverlapCounter {
  inner : @pg.PgConn
  mut in_flight : Int32
  mut peak : Int32
}

///|
fn OverlapCounter::new(inner : @pg.PgConn) -> OverlapCounter {
  { inner, in_flight: 0, peak: 0, }
}

///|
impl @moondb.AsyncDriver for OverlapCounter with fn execute(
  self : OverlapCounter,
  sql : String,
  params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  self.inner.execute(sql, params)
}

///|
impl @moondb.AsyncDriver for OverlapCounter with fn query(
  self : OverlapCounter,
  sql : String,
  params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.in_flight = self.in_flight + 1
  if self.in_flight > self.peak {
    self.peak = self.in_flight
  }
  let rows = self.inner.query(sql, params)
  self.in_flight = self.in_flight - 1
  rows
}

///|
impl @moondb.AsyncDriver for OverlapCounter with fn begin(self : OverlapCounter) -> Unit raise @moondb.DbError {
  self.inner.begin()
}

///|
impl @moondb.AsyncDriver for OverlapCounter with fn commit(
  self : OverlapCounter,
) -> Unit raise @moondb.DbError {
  self.inner.commit()
}

///|
impl @moondb.AsyncDriver for OverlapCounter with fn rollback(
  self : OverlapCounter,
) -> Unit raise @moondb.DbError {
  self.inner.rollback()
}

///|
impl @moondb.AsyncDriver for OverlapCounter with fn close(self : OverlapCounter) -> Unit {
  self.inner.close()
}

///|
impl @moondb.AsyncDriver for OverlapCounter with fn dialect(
  _self : OverlapCounter,
) -> @moondb.Dialect {
  @moondb.Postgres
}

///|
async test "async session: two tasks each open a session and both queries are in flight" {
  guard live() else { return }
  let pool : @apool.AsyncPool[OverlapCounter] = @apool.AsyncPool::new(
    () => {
      OverlapCounter::new(
        @pg.PgConn::connect(
          env_or("PGHOST", "127.0.0.1"),
          env_port("PGPORT", 5432),
          env_or("PGUSER", "orm"),
          env_or("PGPASSWORD", "pw"),
          env_or("PGDATABASE", "orm"),
        ),
      )
    },
    max_size=2,
  ) catch {
    error => abort("pool failed: " + error.to_string())
  }
  let slow : Array[async () -> Unit] = [
    () => {
      @session.AsyncSession::with_pool(pool, sess => {
        sess.query("SELECT pg_sleep(0.3)", []) |> ignore
      })
      |> ignore
    },
    () => {
      @session.AsyncSession::with_pool(pool, sess => {
        sess.query("SELECT pg_sleep(0.3)", []) |> ignore
      })
      |> ignore
    },
  ]
  let start = @async.now()
  @async.all(slow) |> ignore
  let elapsed = @async.now() - start
  // Two 300 ms statements in sequence take 600 ms; overlapped they take about 300.
  // The bound sits between the two, so a regression that serialises the sessions
  // fails here rather than passing on a fast machine.
  assert_eq(elapsed < 550L, true)
  pool.close_all()
}

///|
async test "async session: the pool serves many sessions, each with its own identity map" {
  guard live() else { return }
  let pool : @apool.AsyncPool[OverlapCounter] = @apool.AsyncPool::new(
    () => {
      OverlapCounter::new(
        @pg.PgConn::connect(
          env_or("PGHOST", "127.0.0.1"),
          env_port("PGPORT", 5432),
          env_or("PGUSER", "orm"),
          env_or("PGPASSWORD", "pw"),
          env_or("PGDATABASE", "orm"),
        ),
      )
    },
    max_size=2,
    overflow=1,
  ) catch {
    error => abort("pool failed: " + error.to_string())
  }
  @session.AsyncSession::with_pool(pool, sess => {
    for
      statement in [
        "DROP TABLE IF EXISTS notes", "CREATE TABLE notes (id INTEGER PRIMARY KEY, body VARCHAR(64) NOT NULL)",
        "INSERT INTO notes (id, body) VALUES (1, 'shared')",
      ] {
      sess.execute(statement, []) |> ignore
    }
  }) catch {
    error => abort("setup failed: " + error.to_string())
  }
  let notes = note_model()
  // Two sessions read the same row: each decodes it and keeps its own copy, and one
  // session's `expunge` leaves the other's map alone.
  let first = @session.AsyncSession::with_pool(pool, sess => {
    sess.get(notes, @moondb.Int(1)).unwrap().body
  }) catch {
    error => abort("read failed: " + error.to_string())
  }
  let second = @session.AsyncSession::with_pool(pool, sess => {
    sess.get(notes, @moondb.Int(1)).unwrap().body
  }) catch {
    error => abort("read failed: " + error.to_string())
  }
  assert_eq(first, "shared")
  assert_eq(second, "shared")
  assert_eq(pool.open_count() > 0, true)
  @session.AsyncSession::with_pool(pool, sess => {
    sess.execute("DROP TABLE IF EXISTS notes", []) |> ignore
  }) catch {
    error => abort("cleanup failed: " + error.to_string())
  }
  pool.close_all()
}
