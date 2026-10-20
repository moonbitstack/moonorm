///|
/// Versioned schema migrations (Alembic / Diesel-migrations): a `Migration` bundles a
/// version with its forward (`up`) and reverse (`down`) statements; a `Migrator` records
/// applied versions in a bookkeeping table and drives the schema forward (`up`, applying
/// only what is pending — idempotent) or back (`down_to`). `current_version` and
/// `applied_versions` report state. Everything travels through the `@moondb.Driver` seam,
/// so the same Migrator runs on any backend. The driver here is a small double modelling
/// the `schema_migrations` bookkeeping table, so the whole example stays backend-free
/// and compiles on every target; against real SQLite/Postgres the Migrator is identical.
///
///     moon run examples/19-migrations
///
/// The bookkeeping table the Migrator maintains, in memory. It interprets exactly the
/// statements `Migrator` issues against `schema_migrations` (defined in migrations.mbt)
/// — the version INSERT/DELETE and the two version SELECTs — and treats every other
/// statement (the migrations' own DDL) as an applied no-op it need not model.
struct SchemaLog {
  applied : Array[(Int32, String)]
  mut closed : Bool
}

///|
fn version_of(v : @moondb.Value) -> Int32 {
  match v {
    Int(n) => n
    Int64(n) => n.to_int()
    _ => -1
  }
}

///|
fn text_of(v : @moondb.Value) -> String {
  match v {
    Text(s) => s
    _ => ""
  }
}

///|
impl @moondb.Driver for SchemaLog with fn execute(
  self : SchemaLog,
  sql : String,
  params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  if self.closed {
    raise @moondb.Closed
  }
  if sql.has_prefix("INSERT INTO schema_migrations") {
    self.applied.push((version_of(params[0]), text_of(params[1])))
  } else if sql.has_prefix("DELETE FROM schema_migrations") {
    let target = version_of(params[0])
    for i = 0; i < self.applied.length(); i = i + 1 {
      if self.applied[i].0 == target {
        self.applied.remove(i) |> ignore
        break
      }
    }
  }
  { rows_affected: 1L, last_insert_id: 0L, }
}

///|
impl @moondb.Driver for SchemaLog with fn query(
  self : SchemaLog,
  sql : String,
  params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  if self.closed {
    raise @moondb.Closed
  }
  let out : Array[@moondb.Row] = []
  let row = fn(version : Int32) -> @moondb.Row {
    { columns: ["version"], values: [@moondb.Int(version)], }
  }
  if sql.has_prefix("SELECT version FROM schema_migrations WHERE version") {
    let target = version_of(params[0])
    for entry in self.applied {
      if entry.0 == target {
        out.push(row(entry.0))
      }
    }
  } else if sql.has_prefix("SELECT version FROM schema_migrations") {
    let versions = self.applied.map(fn(e) { e.0 })
    versions.sort()
    for v in versions {
      out.push(row(v))
    }
  }
  out
}

///|
impl @moondb.Driver for SchemaLog with fn begin(_self : SchemaLog) -> Unit raise @moondb.DbError {

}

///|
impl @moondb.Driver for SchemaLog with fn commit(_self : SchemaLog) -> Unit raise @moondb.DbError {

}

///|
impl @moondb.Driver for SchemaLog with fn rollback(_self : SchemaLog) -> Unit raise @moondb.DbError {

}

///|
impl @moondb.Driver for SchemaLog with fn close(self : SchemaLog) -> Unit {
  self.closed = true
}

///|
#coverage.skip
fn main {
  // Two migrations, handed in out of version order — the Migrator sorts them.
  let v1 : @moonorm.Migration = {
    version: 1,
    name: "create_heroes",
    up: ["CREATE TABLE heroes (id INTEGER PRIMARY KEY, name TEXT NOT NULL)"],
    down: ["DROP TABLE heroes"],
  }
  let v2 : @moonorm.Migration = {
    version: 2,
    name: "create_teams",
    up: [
      "CREATE TABLE teams (id INTEGER PRIMARY KEY, name TEXT NOT NULL)", "CREATE INDEX idx_teams_name ON teams (name)",
    ],
    down: ["DROP INDEX idx_teams_name", "DROP TABLE teams"],
  }
  let migrations = [v2, v1]
  try {
    let sess = @moonorm.Session::new(SchemaLog::{ applied: [], closed: false, })
    let mig = @moonorm.Migrator::new()
    println("current version: \{mig.current_version(sess)}")
    let n = mig.up(sess, migrations)
    println("applied \{n} migrations -> version \{mig.current_version(sess)}")
    println(
      "applied versions: " +
      mig.applied_versions(sess).map(fn(v) { v.to_string() }).join(", "),
    )

    // Re-running up() is idempotent: nothing is pending.
    println("second up() applied: \{mig.up(sess, migrations)}")

    // Roll back everything above version 1.
    let back = mig.down_to(sess, migrations, 1)
    println(
      "rolled back \{back} migrations -> version \{mig.current_version(sess)}",
    )
    println(
      "applied versions: " +
      mig.applied_versions(sess).map(fn(v) { v.to_string() }).join(", "),
    )
    sess.close()
  } catch {
    e => println("migration error: " + e.to_string())
  }
}
