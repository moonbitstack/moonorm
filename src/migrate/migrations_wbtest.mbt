///|
/// Read a Value expected to be an Int (the version column). A wrong shape is a bug
/// in the test's own driver double, so it aborts rather than masking it.
fn @moondb.Value::_as_int(self : @moondb.Value) -> Int32 {
  match self {
    Int(v) => v
    _ => abort("tracker driver: expected an Int version, got \{self}")
  }
}

///|
/// A driver that models only the migrations bookkeeping table plus a log of the
/// migration bodies it ran, by interpreting the specific SQL the Migrator emits.
struct TrackerDriver {
  mut versions : Array[Int32] // the schema_migrations rows (version column)
  ran : Array[String] // migration up/down bodies, in execution order
}

///|
fn TrackerDriver::new() -> TrackerDriver {
  { versions: [], ran: [], }
}

///|
pub impl @moondb.Driver for TrackerDriver with fn execute(self, sql, params) {
  if sql.contains("CREATE TABLE IF NOT EXISTS") {
    // ensure_table — nothing to model.
    ()
  } else if sql.has_prefix("INSERT INTO") && sql.contains("(version, name)") {
    self.versions.push(params[0]._as_int())
  } else if sql.has_prefix("DELETE FROM") && sql.contains("WHERE version") {
    let v = params[0]._as_int()
    let kept : Array[Int32] = []
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
    let sorted : Array[Int32] = []
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

///|
fn pg_row(name : String, ty : String, nullable : String) -> @moondb.Row {
  {
    columns: ["column_name", "data_type", "is_nullable"],
    values: [@moondb.Text(name), @moondb.Text(ty), @moondb.Text(nullable)],
  }
}

///|
fn my_row(
  field : String,
  ty : String,
  null_ : String,
  key : String,
  extra : String,
) -> @moondb.Row {
  {
    columns: ["Field", "Type", "Null", "Key", "Default", "Extra"],
    values: [
      @moondb.Text(field),
      @moondb.Text(ty),
      @moondb.Text(null_),
      @moondb.Text(key),
      @moondb.Text(""),
      @moondb.Text(extra),
    ],
  }
}

///|
/// A row shaped like one PRAGMA table_info record: cid, name, type, notnull,
/// dflt_value, pk.
fn pragma_row(
  cid : Int32,
  name : String,
  ty : String,
  notnull : Int32,
  pk : Int32,
) -> @moondb.Row {
  {
    columns: ["cid", "name", "type", "notnull", "dflt_value", "pk"],
    values: [
      @moondb.Int(cid),
      @moondb.Text(name),
      @moondb.Text(ty),
      @moondb.Int(notnull),
      @moondb.Text(""),
      @moondb.Int(pk),
    ],
  }
}

///|
test "diff_schema reports added, removed, and type-changed columns" {
  let declared = [
    @schema.column("id", IntType, primary_key=true),
    @schema.column("name", TextType),
    @schema.column("age", IntType),
  ]
  let reflected = [
    @schema.column("id", IntType, primary_key=true),
    @schema.column("name", TextType),
    @schema.column("email", TextType),
  ]
  // age is in the model only (Added); email only in the db (Removed); id/name match.
  let d = diff_schema(declared, reflected)
  assert_eq(d.length(), 2)
  assert_eq(d[0] == Added(name="age", col_type=IntType), true)
  assert_eq(d[1] == Removed("email"), true)
}

///|
test "diff_schema flags a changed column type" {
  let d = diff_schema([@schema.column("score", IntType)], [
    @schema.column("score", RealType),
  ])
  assert_eq(d.length(), 1)
  assert_eq(d[0] == TypeChanged(name="score", from=RealType, to=IntType), true)
}

///|
test "diff_schema is empty when the schema matches" {
  let cols = [
    @schema.column("id", IntType, primary_key=true),
    @schema.column("v", TextType),
  ]
  assert_eq(diff_schema(cols, cols).length(), 0)
}

///|
test "index_ddl renders single, composite, and unique indexes" {
  assert_eq(
    index_ddl("idx_email", "users", ["email"], unique=true),
    "CREATE UNIQUE INDEX idx_email ON users (email)",
  )
  assert_eq(
    index_ddl("idx_name_age", "users", ["name", "age"]),
    "CREATE INDEX idx_name_age ON users (name, age)",
  )
}

///|
test "migrator: up applies every pending migration in ascending version order" {
  let drv = TrackerDriver::new()
  let sess = @session.Session::new(drv)
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
  let sess = @session.Session::new(drv)
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
  let sess = @session.Session::new(drv)
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
  let sess = @session.Session::new(drv)
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
test "reflect_columns_pg parses information_schema.columns" {
  let cols = reflect_columns_pg([
    pg_row("id", "integer", "NO"),
    pg_row("flag", "boolean", "NO"),
    pg_row("doc", "jsonb", "YES"),
    pg_row("created", "timestamp without time zone", "YES"),
  ])
  assert_eq(cols.length(), 4)
  assert_eq(cols[0].name, "id")
  assert_eq(cols[0].nullable, false)
  assert_eq(cols[0].col_type == IntType, true)
  assert_eq(cols[1].col_type == BoolType, true)
  assert_eq(cols[2].col_type == JsonType, true)
  assert_eq(cols[3].col_type == DateTimeType, true)
}

///|
test "reflect_columns_mysql parses SHOW COLUMNS with key and auto_increment" {
  let cols = reflect_columns_mysql([
    my_row("id", "int", "NO", "PRI", "auto_increment"),
    my_row("active", "tinyint(1)", "YES", "", ""),
    my_row("name", "varchar(100)", "NO", "", ""),
  ])
  assert_eq(cols[0].primary_key, true)
  assert_eq(cols[0].autoincrement, true)
  assert_eq(cols[0].col_type == IntType, true)
  assert_eq(cols[1].col_type == BoolType, true)
  assert_eq(cols[1].primary_key, false)
  assert_eq(cols[2].col_type == TextType, true)
}

///|
test "reflect_columns parses PRAGMA table_info into declared columns" {
  let rows = [
    pragma_row(0, "id", "INTEGER", 1, 1),
    pragma_row(1, "name", "TEXT", 1, 0),
    pragma_row(2, "score", "REAL", 0, 0),
  ]
  let cols = reflect_columns(rows)
  assert_eq(cols.length(), 3)
  assert_eq(cols[0].name, "id")
  assert_eq(cols[0].primary_key, true)
  assert_eq(cols[0].col_type == IntType, true)
  assert_eq(cols[1].name, "name")
  assert_eq(cols[1].nullable, false)
  assert_eq(cols[1].col_type == TextType, true)
  assert_eq(cols[2].nullable, true)
  assert_eq(cols[2].col_type == RealType, true)
}

///|
test "reflection maps bigint to BigIntType on PostgreSQL and MySQL" {
  let pg = reflect_columns_pg([
    pg_row("id", "bigint", "NO"),
    pg_row("n", "integer", "NO"),
  ])
  assert_eq(pg[0].col_type == BigIntType, true)
  assert_eq(pg[1].col_type == IntType, true)
  let my = reflect_columns_mysql([
    my_row("id", "bigint(20)", "NO", "PRI", "auto_increment"),
    my_row("n", "int(11)", "NO", "", ""),
  ])
  assert_eq(my[0].col_type == BigIntType, true)
  assert_eq(my[1].col_type == IntType, true)
}

///|
test "diff_schema compares as the dialect writes types when one is given" {
  let declared = [@schema.column("id", BigIntType, primary_key=true)]
  let reflected = [@schema.column("id", IntType, primary_key=true)]
  assert_eq(diff_schema(declared, reflected).length(), 1)
  assert_eq(diff_schema(declared, reflected, dialect=Sqlite).length(), 0)
  let d = diff_schema(declared, reflected, dialect=Postgres)
  assert_eq(d.length(), 1)
  assert_eq(d[0] == TypeChanged(name="id", from=IntType, to=BigIntType), true)
}
