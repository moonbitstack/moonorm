///|
/// Schema reflection & diff — the read/compare half of Alembic-style autogenerate.
/// `reflect_columns` parses SQLite `PRAGMA table_info` rows into `Column`s;
/// `reflect_columns_pg` / `reflect_columns_mysql` do the same for PostgreSQL
/// `information_schema.columns` and MySQL `SHOW COLUMNS`; `reflect_table` /
/// `reflect_table_for` run that parser off a live driver. `diff_schema` compares a
/// model's declared columns against the reflected ones (`Added` / `Removed` /
/// `TypeChanged`), and `index_ddl` renders a secondary index. The reflection rows are
/// built here so the whole example stays backend-free and compiles on every target.
///
///     moon run src/examples/20-reflection-diff
fn type_name(t : @moonorm.ColumnType) -> String {
  match t {
    IntType => "int"
    BigIntType => "bigint"
    TextType => "text"
    RealType => "real"
    BlobType => "blob"
    BoolType => "bool"
    VarcharType(n) => "varchar(\{n})"
    NumericType => "numeric"
    DateTimeType => "datetime"
    DateType => "date"
    TimeType => "time"
    UuidType => "uuid"
    JsonType => "json"
  }
}

///|
fn diff_name(d : @moonorm.ColumnDiff) -> String {
  match d {
    Added(name~, col_type~) => "added \{name} (\{type_name(col_type)})"
    Removed(name) => "removed \{name}"
    TypeChanged(name~, from~, to~) =>
      "retyped \{name}: \{type_name(from)} -> \{type_name(to)}"
  }
}

///|
/// A driver returning fixed `PRAGMA table_info`-shaped rows, so `reflect_table` (which
/// queries the driver) runs without a real backend.
struct Pragma {
  rows : Array[@moondb.Row]
}

///|
impl @moondb.Driver for Pragma with fn execute(
  _self : Pragma,
  _sql : String,
  _params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  { rows_affected: 0L, last_insert_id: 0L, }
}

///|
impl @moondb.Driver for Pragma with fn query(
  self : Pragma,
  _sql : String,
  _params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.rows
}

///|
impl @moondb.Driver for Pragma with fn begin(_self : Pragma) -> Unit raise @moondb.DbError {

}

///|
impl @moondb.Driver for Pragma with fn commit(_self : Pragma) -> Unit raise @moondb.DbError {

}

///|
impl @moondb.Driver for Pragma with fn rollback(_self : Pragma) -> Unit raise @moondb.DbError {

}

///|
impl @moondb.Driver for Pragma with fn close(_self : Pragma) -> Unit {

}

///|
/// A `PRAGMA table_info` row: cid, name, type, notnull, dflt_value, pk.
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
      @moondb.Null,
      @moondb.Int(pk),
    ],
  }
}

///|
/// An `information_schema.columns` row: column_name, data_type, is_nullable.
fn pg_row(name : String, ty : String, nullable : String) -> @moondb.Row {
  {
    columns: ["column_name", "data_type", "is_nullable"],
    values: [@moondb.Text(name), @moondb.Text(ty), @moondb.Text(nullable)],
  }
}

///|
/// A `SHOW COLUMNS` row: Field, Type, Null, Key, Default, Extra.
fn mysql_row(
  field : String,
  ty : String,
  nullv : String,
  key : String,
  extra : String,
) -> @moondb.Row {
  {
    columns: ["Field", "Type", "Null", "Key", "Default", "Extra"],
    values: [
      @moondb.Text(field),
      @moondb.Text(ty),
      @moondb.Text(nullv),
      @moondb.Text(key),
      @moondb.Null,
      @moondb.Text(extra),
    ],
  }
}

///|
fn show() -> Unit raise @moondb.DbError {
  // Reflect a SQLite table off its PRAGMA rows.
  let reflected = @moonorm.reflect_columns([
    pragma_row(0, "id", "INTEGER", 1, 1),
    pragma_row(1, "name", "TEXT", 1, 0),
    pragma_row(2, "power", "INTEGER", 0, 0),
  ])
  println("-- reflect_columns (PRAGMA table_info)")
  for c in reflected {
    println(
      "  \{c.name}: \{type_name(c.col_type)} pk=\{c.primary_key} nullable=\{c.nullable}",
    )
  }

  // The model dropped `power` and added `team_id`; diff it against the reflected table.
  let declared = [
    @moonorm.column("id", IntType, primary_key=true),
    @moonorm.column("name", TextType, nullable=false),
    @moonorm.column("team_id", IntType),
  ]
  println("")
  println("-- diff_schema (declared vs reflected)")
  for d in @moonorm.diff_schema(declared, reflected) {
    println("  " + diff_name(d))
  }

  // reflect_table / reflect_table_for run the same parser off a driver.
  let drv = Pragma::{
    rows: [
      pragma_row(0, "id", "INTEGER", 1, 1),
      pragma_row(1, "label", "TEXT", 0, 0),
    ],
  }
  println("")
  println("-- reflect_table off a driver")
  for c in @moonorm.reflect_table(drv, "tags") {
    println("  \{c.name}: \{type_name(c.col_type)}")
  }
  println("-- reflect_table_for(Sqlite)")
  for c in @moonorm.reflect_table_for(drv, "tags", Sqlite) {
    println("  \{c.name}")
  }

  // PostgreSQL and MySQL reflection parsers.
  println("")
  println("-- reflect_columns_pg")
  for
    c in @moonorm.reflect_columns_pg([
      pg_row("id", "integer", "NO"),
      pg_row("meta", "jsonb", "YES"),
      pg_row("uid", "uuid", "NO"),
    ]) {
    println("  \{c.name}: \{type_name(c.col_type)} nullable=\{c.nullable}")
  }
  println("")
  println("-- reflect_columns_mysql")
  for
    c in @moonorm.reflect_columns_mysql([
      mysql_row("id", "int", "NO", "PRI", "auto_increment"),
      mysql_row("active", "tinyint(1)", "NO", "", ""),
      mysql_row("name", "varchar(64)", "YES", "", ""),
    ]) {
    println(
      "  \{c.name}: \{type_name(c.col_type)} pk=\{c.primary_key} auto=\{c.autoincrement}",
    )
  }

  println("")
  println("-- index_ddl")
  println(@moonorm.index_ddl("idx_heroes_name", "heroes", ["name"]))
  println(@moonorm.index_ddl("uq_heroes_uid", "heroes", ["uid"], unique=true))
}

///|
#coverage.skip
fn main {
  show() catch {
    e => println("db error: " + e.to_string())
  }
}
