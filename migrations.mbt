// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Versioned schema migrations — the Alembic/`alembic upgrade`, Diesel-migrations
// counterpart. A `Migration` bundles an integer version with the forward (`up`) and
// reverse (`down`) statement lists; a `Migrator` tracks which versions are applied
// in a `schema_migrations` table and drives the schema forward or back. Everything
// runs through the `@moondb.Driver` seam, so the same migrations apply against the
// MockDriver, real SQLite, or any other backend.

///|
/// One schema change: a monotonically increasing `version`, a human `name`, and the
/// ordered SQL statements that apply it (`up`) and undo it (`down`). Each statement
/// runs through `Session::execute`, so a backend that prepares one statement per
/// call (SQLite) still applies a multi-statement migration.
pub(all) struct Migration {
  version : Int
  name : String
  up : Array[String]
  down : Array[String]
}

///|
/// Tracks and applies migrations against a `schema_migrations`-style bookkeeping
/// table (its name is configurable for coexistence with other tools). Build one
/// with `Migrator::new`.
pub struct Migrator {
  table : String
}

///|
/// A migrator recording applied versions in `table` (default `schema_migrations`).
/// The name must be a bare SQL identifier — it is interpolated as an identifier,
/// never bound — so a non-identifier is refused up front.
pub fn Migrator::new(
  table? : String = "schema_migrations",
) -> Migrator raise @moondb.DbError {
  if !is_ident(table) {
    raise @moondb.QueryError("invalid migrations table name: " + table)
  }
  { table, }
}

///|
/// Create the bookkeeping table if it is absent. Idempotent, so it is safe to call
/// before every `up`/`down`.
pub fn Migrator::ensure_table(
  self : Migrator,
  sess : Session,
) -> Unit raise @moondb.DbError {
  sess.execute(
    "CREATE TABLE IF NOT EXISTS " +
    self.table +
    " (version INTEGER PRIMARY KEY, name TEXT NOT NULL)",
    [],
  )
  |> ignore
}

///|
/// Every applied version, ascending.
pub fn Migrator::applied_versions(
  self : Migrator,
  sess : Session,
) -> Array[Int] raise @moondb.DbError {
  self.ensure_table(sess)
  let rows = sess.query(
    "SELECT version FROM " + self.table + " ORDER BY version ASC",
    [],
  )
  let out : Array[Int] = []
  for r in rows {
    out.push(r.int(0))
  }
  out
}

///|
/// The highest applied version, or `0` when nothing has been applied yet.
pub fn Migrator::current_version(
  self : Migrator,
  sess : Session,
) -> Int raise @moondb.DbError {
  let vs = self.applied_versions(sess)
  if vs.length() == 0 {
    0
  } else {
    vs[vs.length() - 1]
  }
}

///|
/// Whether `version` is recorded as applied.
fn Migrator::is_applied(
  self : Migrator,
  sess : Session,
  version : Int,
) -> Bool raise @moondb.DbError {
  let rows = sess.query(
    "SELECT version FROM " + self.table + " WHERE version = ?",
    [Int(version)],
  )
  rows.length() > 0
}

///|
/// Apply every pending migration (those whose version is not yet recorded), in
/// ascending version order, running each one's `up` statements and recording it.
/// Returns how many were applied. Already-applied versions are skipped, so this is
/// safe to run repeatedly (it converges the schema to the latest version).
pub fn Migrator::up(
  self : Migrator,
  sess : Session,
  migrations : Array[Migration],
) -> Int raise @moondb.DbError {
  self.ensure_table(sess)
  let ordered = sort_by_version(migrations, ascending=true)
  let mut applied = 0
  for m in ordered {
    if self.is_applied(sess, m.version) {
      continue
    }
    for stmt in m.up {
      sess.execute(stmt, []) |> ignore
    }
    sess.execute(
      "INSERT INTO " + self.table + " (version, name) VALUES (?, ?)",
      [Int(m.version), Text(m.name)],
    )
    |> ignore
    applied = applied + 1
  }
  applied
}

///|
/// Roll back every applied migration whose version is greater than `target`, in
/// descending version order, running each one's `down` statements and removing its
/// bookkeeping row. Returns how many were rolled back. `down_to(0)` unwinds
/// everything.
pub fn Migrator::down_to(
  self : Migrator,
  sess : Session,
  migrations : Array[Migration],
  target : Int,
) -> Int raise @moondb.DbError {
  self.ensure_table(sess)
  let ordered = sort_by_version(migrations, ascending=false)
  let mut rolled = 0
  for m in ordered {
    if m.version <= target {
      continue
    }
    if !self.is_applied(sess, m.version) {
      continue
    }
    for stmt in m.down {
      sess.execute(stmt, []) |> ignore
    }
    sess.execute("DELETE FROM " + self.table + " WHERE version = ?", [
      Int(m.version),
    ])
    |> ignore
    rolled = rolled + 1
  }
  rolled
}

///|
/// Return a copy of `migrations` sorted by version. Migrations are typically a
/// handful, so an insertion sort keeps the code obvious and stable (equal versions
/// keep their input order, though versions are expected unique).
fn sort_by_version(
  migrations : Array[Migration],
  ascending~ : Bool,
) -> Array[Migration] {
  let out : Array[Migration] = []
  for m in migrations {
    out.push(m)
  }
  for i in 1..<out.length() {
    let key = out[i]
    let mut j = i - 1
    while j >= 0 {
      let greater = out[j].version > key.version
      let move_it = if ascending { greater } else { !greater }
      if move_it {
        out[j + 1] = out[j]
        j = j - 1
      } else {
        break
      }
    }
    out[j + 1] = key
  }
  out
}

///|
/// Map a SQLite declared type keyword back to a `ColumnType` (the inverse of
/// `ColumnType::sql`). Unknown affinities fall back to `TextType`.
fn coltype_of(kw : String) -> ColumnType {
  match kw {
    "INTEGER" => IntType
    "TEXT" => TextType
    "REAL" => RealType
    "BLOB" => BlobType
    "NUMERIC" => NumericType
    "DATETIME" => DateTimeType
    "DATE" => DateType
    "TIME" => TimeType
    _ => TextType
  }
}

///|
/// Parse `PRAGMA table_info` rows into `Column`s — the reflection core, testable
/// without a live database. The pragma projects, in order, `cid, name, type,
/// notnull, dflt_value, pk`; a non-zero `pk` marks the primary key and `notnull`
/// its NOT NULL. This is the read half of Alembic-style autogenerate: compare the
/// reflected columns against a `Model`'s declared columns to diff a schema.
pub fn reflect_columns(
  rows : Array[@moondb.Row],
) -> Array[Column] raise @moondb.DbError {
  let cols = []
  for r in rows {
    cols.push(
      column(
        r.text(1),
        coltype_of(r.text(2)),
        primary_key=r.int(5) != 0,
        nullable=r.int(3) == 0,
      ),
    )
  }
  cols
}

///|
/// Reflect a table's columns off a live connection: run `PRAGMA table_info` and
/// parse it. The thin driver wrapper over `reflect_columns`.
pub fn reflect_table(
  driver : &@moondb.Driver,
  table : String,
) -> Array[Column] raise @moondb.DbError {
  // PRAGMA takes an identifier, not a bindable parameter, so the name is validated
  // rather than concatenated blind — the same is_ident discipline the rest uses.
  guard is_ident(table) else {
    raise @moondb.QueryError(
      "reflect_table: invalid table identifier '\{table}'",
    )
  }
  reflect_columns(driver.query("PRAGMA table_info(" + table + ")", []))
}

///|
/// One difference between a declared schema and a reflected one (Alembic-autogenerate
/// style): a column `Added` in the model but absent in the database, one `Removed`
/// from the model but still present, or one whose `TypeChanged`. Compared by column
/// name; ordering follows the declared columns, then the leftover reflected ones.
pub(all) enum ColumnDiff {
  Added(name~ : String, col_type~ : ColumnType)
  Removed(String)
  TypeChanged(name~ : String, from~ : ColumnType, to~ : ColumnType)
} derive(Eq)

///|
/// The first column named `name`, or `None`.
fn find_col(cols : Array[Column], name : String) -> Column? {
  cols.iter().find_first(fn(c) { c.name == name })
}

///|
/// Diff a model's `declared` columns against the `reflected` ones from a live table:
/// declared-only columns are `Added`, reflected-only are `Removed`, and a name in
/// both with a different `col_type` is `TypeChanged`. An empty result means the table
/// matches the model. This is the write half of autogenerate — feed the diff to DDL
/// to synthesise the migration.
///
/// Scope: reflection recovers only a column's storage type, so declare a model at the
/// same granularity to avoid spurious diffs — a `Bool` stored as `INTEGER` reflects as
/// `Int`, `Uuid`/`Json` stored as `TEXT` reflect as `Text`. And the diff reports
/// add/remove/type only, not nullable / default / unique / PK / FK changes.
pub fn diff_schema(
  declared : Array[Column],
  reflected : Array[Column],
) -> Array[ColumnDiff] {
  let out : Array[ColumnDiff] = []
  for d in declared {
    match find_col(reflected, d.name) {
      Some(r) =>
        if d.col_type != r.col_type {
          out.push(TypeChanged(name=d.name, from=r.col_type, to=d.col_type))
        }
      None => out.push(Added(name=d.name, col_type=d.col_type))
    }
  }
  for r in reflected {
    if find_col(declared, r.name) is None {
      out.push(Removed(r.name))
    }
  }
  out
}

///|
/// Render a `CREATE INDEX` statement (SQLAlchemy's `Index` / `index=True`). With
/// `unique=true` it is a `CREATE UNIQUE INDEX`; multiple `columns` make a composite
/// index. Names are trusted identifiers, never bound. Pair it with a `Migration`'s
/// `up`, and a `DROP INDEX` in its `down`.
pub fn index_ddl(
  name : String,
  table : String,
  columns : Array[String],
  unique? : Bool = false,
) -> String {
  let kw = if unique { "CREATE UNIQUE INDEX " } else { "CREATE INDEX " }
  kw + name + " ON " + table + " (" + join(columns, ", ") + ")"
}

///|
/// Map a PostgreSQL `information_schema.columns.data_type` back to a `ColumnType`.
fn coltype_of_pg(ty : String) -> ColumnType {
  match ty {
    "integer" | "bigint" | "smallint" => IntType
    "boolean" => BoolType
    "double precision" | "real" => RealType
    "bytea" => BlobType
    "numeric" => NumericType
    "timestamp without time zone" | "timestamp with time zone" | "timestamp" =>
      DateTimeType
    "date" => DateType
    "time without time zone" | "time" => TimeType
    "uuid" => UuidType
    "jsonb" | "json" => JsonType
    _ => TextType
  }
}

///|
/// Map a MySQL column `Type` (e.g. `int`, `varchar(255)`, `tinyint(1)`) back to a
/// `ColumnType`. Matched on the base keyword, most specific first.
fn coltype_of_mysql(ty : String) -> ColumnType {
  if ty.has_prefix("tinyint(1)") {
    BoolType
  } else if ty.has_prefix("int") ||
    ty.has_prefix("bigint") ||
    ty.has_prefix("smallint") ||
    ty.has_prefix("tinyint") {
    IntType
  } else if ty.has_prefix("varchar") || ty.has_prefix("char") {
    TextType
  } else if ty.has_prefix("text") {
    TextType
  } else if ty.has_prefix("double") || ty.has_prefix("float") {
    RealType
  } else if ty.has_prefix("blob") {
    BlobType
  } else if ty.has_prefix("decimal") || ty.has_prefix("numeric") {
    NumericType
  } else if ty.has_prefix("datetime") || ty.has_prefix("timestamp") {
    DateTimeType
  } else if ty.has_prefix("date") {
    DateType
  } else if ty.has_prefix("time") {
    TimeType
  } else if ty.has_prefix("json") {
    JsonType
  } else {
    TextType
  }
}

///|
/// Parse PostgreSQL `information_schema.columns` rows (`column_name`, `data_type`,
/// `is_nullable`) into `Column`s — the PG counterpart of `reflect_columns`.
pub fn reflect_columns_pg(
  rows : Array[@moondb.Row],
) -> Array[Column] raise @moondb.DbError {
  let cols = []
  for r in rows {
    cols.push(
      column(r.text(0), coltype_of_pg(r.text(1)), nullable=r.text(2) == "YES"),
    )
  }
  cols
}

///|
/// Parse MySQL `SHOW COLUMNS` rows (`Field`, `Type`, `Null`, `Key`, `Default`,
/// `Extra`) into `Column`s, recovering the primary key (`Key == "PRI"`) and
/// autoincrement (`Extra` contains `auto_increment`).
pub fn reflect_columns_mysql(
  rows : Array[@moondb.Row],
) -> Array[Column] raise @moondb.DbError {
  let cols = []
  for r in rows {
    cols.push(
      column(
        r.text(0),
        coltype_of_mysql(r.text(1)),
        nullable=r.text(2) == "YES",
        primary_key=r.text(3) == "PRI",
        autoincrement=r.text(5).contains("auto_increment"),
      ),
    )
  }
  cols
}

///|
/// Reflect a table's columns off a live connection for a specific `Dialect`: SQLite
/// via `PRAGMA table_info`, PostgreSQL via `information_schema.columns`, MySQL via
/// `SHOW COLUMNS`. The multi-dialect counterpart of `reflect_table`.
pub fn reflect_table_for(
  driver : &@moondb.Driver,
  table : String,
  dialect : Dialect,
) -> Array[Column] raise @moondb.DbError {
  match dialect {
    Sqlite => reflect_table(driver, table)
    Postgres =>
      reflect_columns_pg(
        driver.query(
          "SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_name = ? ORDER BY ordinal_position",
          [Text(table)],
        ),
      )
    Mysql => {
      // SHOW COLUMNS names an identifier, not a bindable parameter — validate it.
      guard is_ident(table) else {
        raise @moondb.QueryError("reflect: invalid table identifier '\{table}'")
      }
      reflect_columns_mysql(driver.query("SHOW COLUMNS FROM " + table, []))
    }
  }
}

///|
pub extend ColumnDiff with Eq::{not_equal, equal}
