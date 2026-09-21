// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The migration engine over a genuine in-memory `schema_migrations` double: unlike
// the naive MockDriver echo store, `TrackerDriver` actually interprets the handful
// of statements the Migrator issues (create the table, insert/delete a version,
// look a version up, list them ordered) and records the order migration bodies run
// in. So the engine's real behaviour — apply pending ascending, skip already-applied
// (idempotent re-run), roll back descending, track the current version — is
// exercised and mutation-checkable on every backend. Applying migrations against a
// real SQLite database is covered separately by moonsqlite's native suite.

///|
/// A driver that models only the migrations bookkeeping table plus a log of the
/// migration bodies it ran, by interpreting the specific SQL the Migrator emits.
struct TrackerDriver {
  mut versions : Array[Int] // the schema_migrations rows (version column)
  ran : Array[String] // migration up/down bodies, in execution order
}

///|
fn TrackerDriver::new() -> TrackerDriver {
  { versions: [], ran: [], }
}

///|
fn starts_with(s : String, prefix : String) -> Bool {
  if s.length() < prefix.length() {
    return false
  }
  s[0:prefix.length()].to_owned() == prefix
}

///|
pub impl @moondb.Driver for TrackerDriver with fn execute(self, sql, params) {
  if sql.contains("CREATE TABLE IF NOT EXISTS") {
    // ensure_table — nothing to model.
    ()
  } else if starts_with(sql, "INSERT INTO") && sql.contains("(version, name)") {
    self.versions.push(params[0]._as_int())
  } else if starts_with(sql, "DELETE FROM") && sql.contains("WHERE version") {
    let v = params[0]._as_int()
    let kept : Array[Int] = []
    for existing in self.versions {
      if existing != v {
        kept.push(existing)
      }
    }
    self.versions = kept
  } else {
    // A migration body statement (up or down): record that it ran.
    self.ran.push(sql)
  }
  { rows_affected: 1, last_insert_id: 0, }
}

///|
pub impl @moondb.Driver for TrackerDriver with fn query(self, sql, params) {
  if sql.contains("WHERE version = ?") {
    let v = params[0]._as_int()
    if self.versions.contains(v) {
      [{ columns: ["version"], values: [Int(v)], }]
    } else {
      []
    }
  } else {
    // list ascending
    let sorted : Array[Int] = []
    for v in self.versions {
      sorted.push(v)
    }
    sorted.sort()
    let rows : Array[@moondb.Row] = []
    for v in sorted {
      rows.push({ columns: ["version"], values: [Int(v)], })
    }
    rows
  }
}

///|
pub impl @moondb.Driver for TrackerDriver with fn begin(_self) -> Unit raise @moondb.DbError {

}

///|
pub impl @moondb.Driver for TrackerDriver with fn commit(_self) -> Unit raise @moondb.DbError {

}

///|
pub impl @moondb.Driver for TrackerDriver with fn rollback(_self) -> Unit raise @moondb.DbError {

}

///|
pub impl @moondb.Driver for TrackerDriver with fn close(_self) -> Unit {

}

///|
/// Read a Value expected to be an Int (the version column). A wrong shape is a bug
/// in the test's own driver double, so it aborts rather than masking it.
fn Value::_as_int(self : Value) -> Int {
  match self {
    Int(v) => v
    _ => abort("tracker driver: expected an Int version, got \{self}")
  }
}

///|
/// Three migrations, deliberately out of version order in the input array so the
/// engine's own sort is what puts them in sequence.
fn sample_migrations() -> Array[Migration] {
  [
    {
      version: 2,
      name: "add_email",
      up: ["ALTER TABLE users ADD COLUMN email TEXT"],
      down: ["ALTER TABLE users DROP COLUMN email"],
    },
    {
      version: 1,
      name: "create_users",
      up: ["CREATE TABLE users (id INTEGER PRIMARY KEY)"],
      down: ["DROP TABLE users"],
    },
    {
      version: 3,
      name: "index_email",
      up: ["CREATE INDEX ix_users_email ON users (email)"],
      down: ["DROP INDEX ix_users_email"],
    },
  ]
}

///|
test "migrator: up applies every pending migration in ascending version order" {
  let drv = TrackerDriver::new()
  let sess = Session::new(drv)
  let mig = Migrator::new()
  assert_eq(mig.current_version(sess), 0)
  let applied = mig.up(sess, sample_migrations())
  assert_eq(applied, 3)
  assert_eq(mig.current_version(sess), 3)
  assert_eq(mig.applied_versions(sess), [1, 2, 3])
  // The up bodies ran in version order 1, 2, 3 despite the shuffled input.
  assert_eq(drv.ran, [
    "CREATE TABLE users (id INTEGER PRIMARY KEY)", "ALTER TABLE users ADD COLUMN email TEXT",
    "CREATE INDEX ix_users_email ON users (email)",
  ])
}

///|
test "migrator: up is idempotent — a second run applies nothing" {
  let drv = TrackerDriver::new()
  let sess = Session::new(drv)
  let mig = Migrator::new()
  mig.up(sess, sample_migrations()) |> ignore
  drv.ran.clear()
  let again = mig.up(sess, sample_migrations())
  assert_eq(again, 0)
  assert_eq(drv.ran.length(), 0) // no body re-ran
  assert_eq(mig.current_version(sess), 3)
}

///|
test "migrator: a newly added migration applies on top without redoing the rest" {
  let drv = TrackerDriver::new()
  let sess = Session::new(drv)
  let mig = Migrator::new()
  let first_two : Array[Migration] = [
    sample_migrations()[1], // version 1
    sample_migrations()[0], // version 2
  ]
  mig.up(sess, first_two) |> ignore
  assert_eq(mig.current_version(sess), 2)
  drv.ran.clear()
  // Now the full set (which adds version 3) — only 3 should apply.
  let applied = mig.up(sess, sample_migrations())
  assert_eq(applied, 1)
  assert_eq(drv.ran, ["CREATE INDEX ix_users_email ON users (email)"])
  assert_eq(mig.current_version(sess), 3)
}

///|
test "migrator: down_to rolls back above the target, descending, and stops there" {
  let drv = TrackerDriver::new()
  let sess = Session::new(drv)
  let mig = Migrator::new()
  mig.up(sess, sample_migrations()) |> ignore
  drv.ran.clear()
  // Roll back everything above version 1: undo 3 then 2, leaving 1.
  let rolled = mig.down_to(sess, sample_migrations(), 1)
  assert_eq(rolled, 2)
  assert_eq(drv.ran, [
    "DROP INDEX ix_users_email", "ALTER TABLE users DROP COLUMN email",
  ])
  assert_eq(mig.applied_versions(sess), [1])
  assert_eq(mig.current_version(sess), 1)
  // down_to(0) unwinds the last one.
  drv.ran.clear()
  assert_eq(mig.down_to(sess, sample_migrations(), 0), 1)
  assert_eq(drv.ran, ["DROP TABLE users"])
  assert_eq(mig.current_version(sess), 0)
}

///|
test "migrator: a non-identifier table name is refused before any SQL runs" {
  let refused = try {
    Migrator::new(table="mig; DROP TABLE users") |> ignore
    false
  } catch {
    @moondb.QueryError(_) => true
    _ => false
  }
  assert_eq(refused, true)
}

///|
pub extend TrackerDriver with @moondb.Driver::{
  execute,
  begin,
  ping,
  close,
  query_stream,
  commit,
  query,
  rollback,
}
