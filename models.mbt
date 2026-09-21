// The declarative model layer: typed columns, a Row<->record mapper, and
// foreign-key relationships with explicit eager loading. SQLAlchemy derives all of
// this from Python classes at runtime via attribute interception; MoonBit has no
// reflection and no attribute interception, so the mapping is declared explicitly —
// a `Model[T]` descriptor carries the columns plus the two mapping closures
// (Row -> record, record -> bound columns). That is the same faithful, explicit
// trade Diesel (`table!` + `Queryable`/`Insertable`) and GORM make, and it keeps
// the whole layer pure so it compiles on every backend; only the concrete driver
// is native-gated.

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
  VarcharType(Int)
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
  primary_key? : Bool = false,
  autoincrement? : Bool = false,
  nullable? : Bool = true,
  unique? : Bool = false,
  default? : String? = None,
  checks? : Array[String] = [],
  references? : (String, String)? = None,
  on_delete? : String? = None,
  on_update? : String? = None,
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
pub fn Column::ddl(self : Column, inline_pk? : Bool = true) -> String {
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
/// One field of a declarative model: a declared [`Column`] paired with the
/// projection that reads the field's value out of a record `T`. A `Field` is the
/// column metadata plus the "how to persist this one attribute" half of the mapping,
/// factored to one place so a `Model` can be assembled from a list of fields rather
/// than a hand-written `to_columns`.
///
/// This is the shape moonctl's `model` generator emits: from a `#orm`-annotated
/// struct it produces one `field(...)` per attribute (the `encode` closure is a
/// trivial projection like `h => Int(h.id)`), and a single `from_row` decoder. The
/// generated `[Field]` array then drives the column list, the `CREATE TABLE` DDL,
/// the `SELECT` projection, and the `INSERT` binding — everything except decoding a
/// row back into `T`, which needs the record constructor MoonBit cannot synthesise
/// without reflection (see [`Model::from_fields`]).
pub struct Field[T] {
  column : Column
  encode : (T) -> Value
}

///|
/// Declare a model field: its column metadata and the projection `encode` that
/// pulls this field's [`Value`] out of a record. The column knobs (`primary_key`,
/// `nullable`, `references`) mirror [`column`]; `encode` is the one-liner that
/// binds the attribute, e.g. `field("id", IntType, primary_key=true, h =>
/// Int(h.id))`.
pub fn[T] field(
  name : String,
  col_type : ColumnType,
  encode : (T) -> Value,
  primary_key? : Bool = false,
  autoincrement? : Bool = false,
  nullable? : Bool = true,
  unique? : Bool = false,
  default? : String? = None,
  checks? : Array[String] = [],
  references? : (String, String)? = None,
  on_delete? : String? = None,
  on_update? : String? = None,
) -> Field[T] {
  {
    column: {
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
    },
    encode,
  }
}

///|
/// The name of the column this field maps to.
pub fn[T] Field::name(self : Field[T]) -> String {
  self.column.name
}

///|
/// A declarative model: the mapping between a database table and a MoonBit record
/// type `T`. It bundles the `table` name, the ordered `columns`, and the two mapping
/// closures that MoonBit cannot synthesise for want of reflection:
/// `from_row` decodes a fetched `Row` into a `T`, and `to_columns` projects a `T`
/// back into the `(name, Value)` pairs an INSERT binds. Build one with `Model::new`.
///
/// This is the faithful explicit equivalent of a SQLAlchemy declarative class — the
/// columns are the `mapped_column`s, and the two closures are the automatic
/// attribute<->column mapping made visible. Being a plain value it stays pure and
/// compiles on every backend.
pub struct Model[T] {
  table : String
  columns : Array[Column]
  from_row : (@moondb.Row) -> T raise @moondb.DbError
  to_columns : (T) -> Array[(String, Value)]
  // A session's identity map has to hang off the descriptor that carries `T`.
  // MoonBit has no downcast, so a `Session` cannot keep the records of several
  // models in one container and get them back typed; the type-indexed store is the
  // only place the type is still known. The outer key is the session's serial, so
  // two sessions never hand out the same instance, and closing one drops its slot.
  ident : Map[Int, Map[String, T]]
}

///|
/// Define a `Model[T]`. `from_row` should read the record's fields off the
/// `@moondb.Row` (via `Row::text` / `Row::int` / `Row::by_name` …) — those accessors
/// raise `@moondb.DbError` on a type or index mismatch, so `from_row` raises too and
/// a decode bug surfaces at the call site. `to_columns` should list the column/value
/// pairs to persist (typically every column except an autoincrement primary key).
/// Write the closures in arrow form so the `raise` effect is inferred, e.g.
/// `(r) => \{ id: r.int(0), name: r.text(1) \}`.
pub fn[T] Model::new(
  table : String,
  columns : Array[Column],
  from_row : (@moondb.Row) -> T raise @moondb.DbError,
  to_columns : (T) -> Array[(String, Value)],
) -> Model[T] {
  { table, columns, from_row, to_columns, ident: Map([]), }
}

///|
/// Build a `Model[T]` from a list of [`Field`]s and a single row decoder — the
/// declarative path that removes the hand-written `to_columns`. The columns and the
/// binding projection are both derived from `fields`: `columns` is each field's
/// declared column, and `to_columns` maps a record to `(name, field.encode(record))`
/// pairs. You still supply `from_row`, because reconstructing a `T` from a fetched
/// row needs the record constructor, and MoonBit — lacking reflection — cannot
/// synthesise it; that one closure is the irreducible core of the mapping.
///
/// This is the constructor moonctl-generated model metadata targets: the generator
/// emits the `[Field]` array and the `from_row` decoder, and `from_fields` turns
/// them into a live `Model`. Written by hand it reads just as directly:
///
/// ```
/// Model::from_fields(
///   "hero",
///   [
///     field("id", IntType, primary_key=true, h => Int(h.id)),
///     field("name", TextType, nullable=false, h => Text(h.name)),
///   ],
///   r => { id: r.int(0), name: r.text(1) },
/// )
/// ```
pub fn[T] Model::from_fields(
  table : String,
  fields : Array[Field[T]],
  from_row : (@moondb.Row) -> T raise @moondb.DbError,
) -> Model[T] {
  let columns : Array[Column] = []
  for f in fields {
    columns.push(f.column)
  }
  let to_columns = fn(record : T) -> Array[(String, Value)] {
    let out : Array[(String, Value)] = []
    for f in fields {
      out.push((f.column.name, (f.encode)(record)))
    }
    out
  }
  { table, columns, from_row, to_columns, ident: Map([]), }
}

///|
/// The declared column names, in order.
pub fn[T] Model::column_names(self : Model[T]) -> Array[String] {
  let names : Array[String] = []
  for c in self.columns {
    names.push(c.name)
  }
  names
}

///|
/// The declared primary-key column names, in declaration order. Empty when the model
/// declares no key at all — the unit of work needs one to address a row, and
/// `Session::get` / `Session::delete_record` say so rather than guessing.
pub fn[T] Model::pk_columns(self : Model[T]) -> Array[String] {
  let names : Array[String] = []
  for c in self.columns {
    if c.primary_key {
      names.push(c.name)
    }
  }
  names
}

///|
/// A record's primary-key values in `pk_columns` order, read off the same
/// `to_columns` projection an INSERT binds — the only route to them, since MoonBit
/// cannot look up an attribute by name.
///
/// A projection that omits a key column — the usual shape for an autoincrement id
/// the server assigns — stops the scan there, so the result is shorter than
/// `pk_columns`. That length mismatch is how a session tells a record it can address
/// from one whose key does not exist yet.
pub fn[T] Model::pk_of(self : Model[T], record : T) -> Array[Value] {
  let bound = (self.to_columns)(record)
  let out : Array[Value] = []
  for name in self.pk_columns() {
    let mut found = false
    for pair in bound {
      if pair.0 == name {
        out.push(pair.1)
        found = true
        break
      }
    }
    if !found {
      break
    }
  }
  out
}

///|
/// The distinct tables this model's foreign keys point at, itself excluded. A flush
/// orders inserts so every table named here is written before this one, and deletes
/// the other way round.
pub fn[T] Model::parent_tables(self : Model[T]) -> Array[String] {
  let out : Array[String] = []
  for c in self.columns {
    if c.references is Some((t, _)) && t != self.table && !out.contains(t) {
      out.push(t)
    }
  }
  out
}

///|
/// A `Select` over this model's table with every declared column projected
/// explicitly (so the projection order is fixed and known to `from_row`). Add
/// `where_` / `order_by` / `limit` to it as usual, then run it with
/// `Session::fetch_as` to get mapped records back.
pub fn[T] Model::select(self : Model[T]) -> Select {
  let s = select(self.table)
  for c in self.columns {
    s.cols.push(c.name)
  }
  s
}

///|
/// The `Table` descriptor for this model (name + column names), for interop with
/// the plain builder API.
pub fn[T] Model::table_descriptor(self : Model[T]) -> Table {
  { name: self.table, columns: self.column_names(), }
}

///|
/// Render `CREATE TABLE` DDL for this model from its declared columns. With
/// `if_not_exists=true` the statement is idempotent (`CREATE TABLE IF NOT EXISTS`).
/// This is the explicit counterpart of SQLAlchemy's `metadata.create_all()`.
pub fn[T] Model::create_table_sql(
  self : Model[T],
  if_not_exists? : Bool = false,
) -> String {
  let head = if if_not_exists {
    "CREATE TABLE IF NOT EXISTS "
  } else {
    "CREATE TABLE "
  }
  let pks = self.columns.filter(fn(c) { c.primary_key })
  // A single primary key stays inline (`id INTEGER PRIMARY KEY`); a composite key
  // becomes a table-level `PRIMARY KEY (a, b)` constraint, since SQL allows only one
  // inline PRIMARY KEY per table.
  let composite = pks.length() > 1
  let defs : Array[String] = []
  for c in self.columns {
    defs.push(c.ddl(inline_pk=!composite))
  }
  if composite {
    defs.push("PRIMARY KEY (" + join(pks.map(fn(c) { c.name }), ", ") + ")")
  }
  head + self.table + " (" + join(defs, ", ") + ")"
}

///|
/// Build an `Insert` that persists `record`, binding the pairs from `to_columns`.
/// Values travel as `?` placeholders exactly like the rest of the builder.
pub fn[T] Model::insert_of(self : Model[T], record : T) -> Insert {
  let mut ins = insert(self.table)
  for pair in (self.to_columns)(record) {
    ins = ins.set(pair.0, pair.1)
  }
  ins
}

///|
/// Decode a single fetched `Row` into a record via the model's `from_row`.
pub fn[T] Model::map_row(
  self : Model[T],
  row : @moondb.Row,
) -> T raise @moondb.DbError {
  (self.from_row)(row)
}

///|
/// Decode a whole result set into records, preserving row order.
pub fn[T] Model::map_rows(
  self : Model[T],
  rows : Array[@moondb.Row],
) -> Array[T] raise @moondb.DbError {
  let out : Array[T] = []
  for r in rows {
    out.push((self.from_row)(r))
  }
  out
}

///|
/// A foreign-key relationship from a source record `S` to a `target` model `T`,
/// resolved by matching `target.key_column` against a `Value` extracted from the
/// source. `to_many` records the cardinality (a 1:N parent->children link versus a
/// N:1 child->parent link) so callers know whether to expect many rows or one.
///
/// Because MoonBit has no attribute interception, touching `hero.team` cannot
/// silently emit a SELECT the way SQLAlchemy's lazy load does. The relationship is
/// therefore a first-class value and the load is explicit — `Session::load` /
/// `Session::load_one` — exactly the eager, explicit shape Diesel's `belonging_to`
/// / preload and GORM's `Preload` take.
pub struct Relation[S, T] {
  target : Model[T]
  key_column : String
  source_key : (S) -> Value
  to_many : Bool
}

///|
/// A 1:N relationship: `parent` -> its children in `target`, matched by the child's
/// `foreign_key` column equalling the parent key extracted by `parent_key`. Load it
/// with `Session::load`, which returns every matching child record.
pub fn[S, T] has_many(
  target : Model[T],
  foreign_key : String,
  parent_key : (S) -> Value,
) -> Relation[S, T] {
  { target, key_column: foreign_key, source_key: parent_key, to_many: true, }
}

///|
/// A N:1 relationship: `child` -> its single parent in `target`, matched by the
/// parent's `target_key` column (usually its primary key) equalling the foreign
/// key extracted from the child by `child_key`. Load it with `Session::load_one`.
pub fn[S, T] belongs_to(
  target : Model[T],
  target_key : String,
  child_key : (S) -> Value,
) -> Relation[S, T] {
  { target, key_column: target_key, source_key: child_key, to_many: false, }
}

///|
/// The `Select` that resolves this relationship for a given `source` record: the
/// target model's projection filtered to `key_column = ?`, with the source-derived
/// value bound (never spliced), so eager loading is injection-safe like every other
/// query. `Session::load` runs this and maps the rows.
pub fn[S, T] Relation::query(self : Relation[S, T], source : S) -> Select {
  self.target.select().where_(self.key_column, "=", (self.source_key)(source))
}

///|
/// The single `Select` that resolves this relationship for *many* sources at once:
/// the target model's projection filtered to `key_column IN (k1, k2, …)`, where the
/// keys are the distinct values extracted from `sources`. This is the query behind
/// an N+1-avoiding batch load — one round trip fetches the related rows of every
/// source, instead of one `query(source)` per source. Every key binds as its own
/// placeholder. With no sources the result filters on the empty set (`IN (NULL)`),
/// matching nothing; `Session::load_batch` short-circuits that case without a query.
/// The source-side key this relationship extracts from a `source` record — the
/// value the target's `key_column` is matched against. Exposed so a batch load can
/// bucket fetched rows back to their sources.
pub fn[S, T] Relation::source_value(self : Relation[S, T], source : S) -> Value {
  (self.source_key)(source)
}

///|
/// One SELECT covering every source's related rows — `key_column IN (…)` over the
/// sources' keys — so loading a relation for a list costs one query instead of one
/// per row. `source_value` is what buckets the results back.
pub fn[S, T] Relation::batch_query(
  self : Relation[S, T],
  sources : Array[S],
) -> Select {
  let keys : Array[Value] = []
  for s in sources {
    let k = (self.source_key)(s)
    // Distinct keys only: several sources may share one foreign key, and the IN
    // list needs each key once.
    let mut seen = false
    for existing in keys {
      if existing == k {
        seen = true
        break
      }
    }
    if !seen {
      keys.push(k)
    }
  }
  self.target.select().where_in_values(self.key_column, keys)
}

///|
/// A many-to-many relationship from a source `S` to a `target` `T` through a
/// `junction` (association) table — SQLAlchemy's `relationship(secondary=...)`. The
/// junction's `source_fk` column matches a key extracted from the source, and its
/// `target_fk` column matches the target's `target_key`. Resolving the relationship
/// JOINs the target through the junction. Load it with `Session::load_many`; like the
/// 1:N / N:1 relations, MoonBit's lack of attribute interception makes the load an
/// explicit call rather than a lazy attribute access.
pub struct ManyToMany[S, T] {
  target : Model[T]
  junction : String
  source_fk : String
  target_fk : String
  target_key : String
  source_key : (S) -> Value
}

///|
/// Define a many-to-many relationship through `junction`. `source_fk` / `target_fk`
/// are the junction columns pointing at the source key and the `target_key`.
pub fn[S, T] many_to_many(
  target : Model[T],
  junction~ : String,
  source_fk~ : String,
  target_fk~ : String,
  target_key~ : String,
  source_key~ : (S) -> Value,
) -> ManyToMany[S, T] {
  { target, junction, source_fk, target_fk, target_key, source_key, }
}

///|
/// The `Select` resolving this relationship for a `source`: the target rows joined to
/// the junction on `junction.target_fk = target.target_key`, filtered to
/// `junction.source_fk = ?` with the source key bound (never spliced). The target
/// columns are projected qualified (`target.col`) so a same-named junction column
/// never makes the projection ambiguous. `Session::load_many` runs it and maps.
pub fn[S, T] ManyToMany::query(self : ManyToMany[S, T], source : S) -> Select {
  let s = select(self.target.table)
  for c in self.target.columns {
    s.cols.push(self.target.table + "." + c.name)
  }
  s
  .join(
    self.junction,
    self.junction +
    "." +
    self.target_fk +
    " = " +
    self.target.table +
    "." +
    self.target_key,
  )
  .where_(self.junction + "." + self.source_fk, "=", (self.source_key)(source))
}

///|
/// The declared type keyword for a `ColumnType` in a given SQL `Dialect`. SQLite is
/// the affinity-based default; PostgreSQL and MySQL render their native spellings
/// (BOOLEAN/BYTEA/DOUBLE PRECISION/UUID/JSONB on PG; INT/TINYINT(1)/DOUBLE/JSON on
/// MySQL). This is the per-dialect counterpart of `ColumnType::sql`.
pub fn ColumnType::sql_for(self : ColumnType, dialect : Dialect) -> String {
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
  dialect : Dialect,
  inline_pk? : Bool = true,
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
/// `CREATE TABLE` DDL for this model rendered for a specific `Dialect` — the
/// multi-dialect counterpart of `create_table_sql`. Uses `Column::ddl_for`, keeps a
/// composite primary key as a table-level constraint, and appends `ENGINE=InnoDB` on
/// MySQL.
pub fn[T] Model::create_table_sql_for(
  self : Model[T],
  dialect : Dialect,
  if_not_exists? : Bool = false,
) -> String {
  let head = if if_not_exists {
    "CREATE TABLE IF NOT EXISTS "
  } else {
    "CREATE TABLE "
  }
  let pks = self.columns.filter(fn(c) { c.primary_key })
  let composite = pks.length() > 1
  let defs : Array[String] = []
  for c in self.columns {
    defs.push(c.ddl_for(dialect, inline_pk=!composite))
  }
  if composite {
    defs.push("PRIMARY KEY (" + join(pks.map(fn(c) { c.name }), ", ") + ")")
  }
  let tail = if dialect is Mysql { " ENGINE=InnoDB" } else { "" }
  head + self.table + " (" + join(defs, ", ") + ")" + tail
}

///|
pub extend ColumnType with Eq::{not_equal, equal}
