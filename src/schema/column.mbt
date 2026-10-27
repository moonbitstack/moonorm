///|
/// A column's SQL storage type. These map onto SQLite's type affinities when a
/// `Model` renders `CREATE TABLE` DDL: `IntType`/`BoolType` -> INTEGER, `TextType`
/// -> TEXT, `RealType` -> REAL, `BlobType` -> BLOB. `BoolType` is a distinct
/// declared type so DDL reads intently, but binds and reads as an integer `0`/`1`.
pub(all) enum ColumnType {
  IntType
  TextType
  RealType
  BlobType
  BoolType
  // SQLModel's everyday field types beyond the storage affinities. `VarcharType(n)`
  // carries a length; the rest declare a type SQLite tolerates and that a dialect
  // renders natively (see `ColumnType::sql`). UUID/JSON store as TEXT on SQLite.
  VarcharType(Int32)
  NumericType
  DateTimeType
  DateType
  TimeType
  UuidType
  JsonType
} derive(Eq)

///|
/// The SQLite declared type keyword for a `ColumnType`.
fn ColumnType::sql(self : ColumnType) -> String {
  match self {
    IntType => "INTEGER"
    BoolType => "INTEGER"
    TextType => "TEXT"
    RealType => "REAL"
    BlobType => "BLOB"
    VarcharType(n) => "VARCHAR(" + n.to_string() + ")"
    NumericType => "NUMERIC"
    DateTimeType => "DATETIME"
    DateType => "DATE"
    TimeType => "TIME"
    // SQLite has no native UUID/JSON storage class; they live as TEXT (a dialect
    // renders UUID / JSONB natively — see sql_for).
    UuidType => "TEXT"
    JsonType => "TEXT"
  }
}

///|
/// One declared column of a `Model`: its `name`, storage `col_type`, whether it is
/// the (or part of the) primary key, whether it accepts NULL, and an optional
/// foreign-key `references` target `(table, column)`. This is the explicit stand-in
/// for SQLAlchemy's `mapped_column(...)` — every fact that framework reads off the
/// annotated attribute is stated here as data.
pub(all) struct Column {
  name : String
  col_type : ColumnType
  primary_key : Bool
  // A server-generated key (SQLAlchemy `autoincrement` / SERIAL / AUTO_INCREMENT).
  // On SQLite, an autoincrement primary key renders `INTEGER PRIMARY KEY AUTOINCREMENT`.
  autoincrement : Bool
  nullable : Bool
  unique : Bool
  // A DDL `DEFAULT` expression (SQLAlchemy `server_default`), e.g. `"0"` or
  // `"CURRENT_TIMESTAMP"`. A trusted SQL literal, emitted verbatim, never bound.
  default : String?
  // Column-level `CHECK (expr)` constraints (SQLAlchemy CheckConstraint / column
  // `CHECK`), each a trusted SQL expression.
  checks : Array[String]
  references : (String, String)?
  // Referential actions on the foreign key (SQLAlchemy ForeignKey ondelete/onupdate),
  // e.g. `"CASCADE"` / `"SET NULL"` / `"RESTRICT"`. Emitted only when `references` is
  // set.
  on_delete : String?
  on_update : String?
}

///|
/// Declare a `Column`. `primary_key` and `references` default off; a primary-key
/// column is `NOT NULL` implicitly (SQLite treats INTEGER PRIMARY KEY as the
/// rowid), and `nullable` defaults to `true` for every other column, matching
/// SQLAlchemy's `nullable=True` default.
pub fn column(
  name : String,
  col_type : ColumnType,
  primary_key~ : Bool = false,
  autoincrement~ : Bool = false,
  nullable~ : Bool = true,
  unique~ : Bool = false,
  default? : String,
  checks~ : Array[String] = [],
  references? : (String, String),
  on_delete? : String,
  on_update? : String,
) -> Column {
  {
    name,
    col_type,
    primary_key,
    autoincrement,
    nullable,
    unique,
    default,
    checks,
    references,
    on_delete,
    on_update,
  }
}

///|
/// Render this column as a single `CREATE TABLE` column definition, e.g.
/// `"user_id INTEGER NOT NULL REFERENCES users(id)"`. A `PRIMARY KEY` column emits
/// that keyword; a non-nullable column emits `NOT NULL`; a `references` target
/// emits a `REFERENCES table(column)` clause. Column and table names are trusted
/// identifiers declared in code, never bound values.
pub fn Column::ddl(self : Column, inline_pk~ : Bool = true) -> String {
  let mut s = self.name + " " + self.col_type.sql()
  if self.primary_key && inline_pk {
    s = s + " PRIMARY KEY"
    if self.autoincrement {
      s = s + " AUTOINCREMENT"
    }
  } else if self.primary_key || !self.nullable {
    // A primary-key column is NOT NULL; when the key is a table-level constraint
    // (composite key, `inline_pk=false`) the column still carries NOT NULL.
    s = s + " NOT NULL"
  }
  if self.unique && !self.primary_key {
    s = s + " UNIQUE"
  }
  if self.default is Some(expr) {
    s = s + " DEFAULT " + expr
  }
  for chk in self.checks {
    s = s + " CHECK (" + chk + ")"
  }
  match self.references {
    Some((t, c)) => {
      s = s + " REFERENCES " + t + "(" + c + ")"
      if self.on_delete is Some(act) {
        s = s + " ON DELETE " + act
      }
      if self.on_update is Some(act) {
        s = s + " ON UPDATE " + act
      }
    }
    None => ()
  }
  s
}

///|
/// The declared type keyword for a `ColumnType` in a given SQL `Dialect`. SQLite is
/// the affinity-based default; PostgreSQL and MySQL render their native spellings
/// (BOOLEAN/BYTEA/DOUBLE PRECISION/UUID/JSONB on PG; INT/TINYINT(1)/DOUBLE/JSON on
/// MySQL). This is the per-dialect counterpart of `ColumnType::sql`.
pub fn ColumnType::sql_for(
  self : ColumnType,
  dialect : @query.Dialect,
) -> String {
  match (self, dialect) {
    (IntType, Mysql) => "INT"
    (IntType, _) => "INTEGER"
    (BoolType, Postgres) => "BOOLEAN"
    (BoolType, Mysql) => "TINYINT(1)"
    (BoolType, _) => "INTEGER"
    (RealType, Postgres) => "DOUBLE PRECISION"
    (RealType, Mysql) => "DOUBLE"
    (RealType, _) => "REAL"
    (BlobType, Postgres) => "BYTEA"
    (BlobType, _) => "BLOB"
    (VarcharType(n), _) => "VARCHAR(" + n.to_string() + ")"
    (NumericType, _) => "NUMERIC"
    (DateTimeType, Postgres) => "TIMESTAMP"
    (DateTimeType, _) => "DATETIME"
    (DateType, _) => "DATE"
    (TimeType, _) => "TIME"
    (UuidType, Postgres) => "UUID"
    (UuidType, Mysql) => "CHAR(36)"
    (UuidType, _) => "TEXT"
    (JsonType, Postgres) => "JSONB"
    (JsonType, Mysql) => "JSON"
    (JsonType, _) => "TEXT"
    (TextType, _) => "TEXT"
  }
}

///|
/// A column definition rendered for a specific `Dialect`. An autoincrement primary
/// key takes each engine's idiom: SQLite `INTEGER PRIMARY KEY AUTOINCREMENT`,
/// PostgreSQL `SERIAL PRIMARY KEY`, MySQL `INT AUTO_INCREMENT PRIMARY KEY`. Otherwise
/// it is `sql_for` plus the same constraint clauses as `ddl`.
pub fn Column::ddl_for(
  self : Column,
  dialect : @query.Dialect,
  inline_pk~ : Bool = true,
) -> String {
  let mut s = if self.primary_key && inline_pk && self.autoincrement {
    match dialect {
      Postgres => self.name + " SERIAL PRIMARY KEY"
      Mysql => self.name + " INT AUTO_INCREMENT PRIMARY KEY"
      Sqlite => self.name + " INTEGER PRIMARY KEY AUTOINCREMENT"
    }
  } else {
    let mut d = self.name + " " + self.col_type.sql_for(dialect)
    if self.primary_key && inline_pk {
      d = d + " PRIMARY KEY"
    } else if self.primary_key || !self.nullable {
      d = d + " NOT NULL"
    }
    d
  }
  if self.unique && !self.primary_key {
    s = s + " UNIQUE"
  }
  if self.default is Some(expr) {
    s = s + " DEFAULT " + expr
  }
  for chk in self.checks {
    s = s + " CHECK (" + chk + ")"
  }
  match self.references {
    Some((t, c)) => {
      s = s + " REFERENCES " + t + "(" + c + ")"
      if self.on_delete is Some(act) {
        s = s + " ON DELETE " + act
      }
      if self.on_update is Some(act) {
        s = s + " ON UPDATE " + act
      }
    }
    None => ()
  }
  s
}

///|
pub extend ColumnType with Eq::{not_equal, equal}
