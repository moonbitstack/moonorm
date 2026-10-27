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
  encode : (T) -> @moondb.Value
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
  encode : (T) -> @moondb.Value,
  primary_key~ : Bool = false,
  autoincrement~ : Bool = false,
  nullable~ : Bool = true,
  unique~ : Bool = false,
  default? : String,
  checks~ : Array[String] = [],
  references? : (String, String),
  on_delete? : String,
  on_update? : String,
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
  to_columns : (T) -> Array[(String, @moondb.Value)]
  // A session's identity map has to hang off the descriptor that carries `T`.
  // MoonBit has no downcast, so a `Session` cannot keep the records of several
  // models in one container and get them back typed; the type-indexed store is the
  // only place the type is still known. The outer key is the session's serial, so
  // two sessions never hand out the same instance, and closing one drops its slot.
  ident : Map[Int32, Map[String, T]]
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
  to_columns : (T) -> Array[(String, @moondb.Value)],
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
  let to_columns = fn(record : T) -> Array[(String, @moondb.Value)] {
    let out : Array[(String, @moondb.Value)] = []
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
pub fn[T] Model::pk_of(self : Model[T], record : T) -> Array[@moondb.Value] {
  let bound = (self.to_columns)(record)
  let out : Array[@moondb.Value] = []
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
pub fn[T] Model::select(self : Model[T]) -> @query.Select {
  let s = @query.select(self.table)
  for c in self.columns {
    s.cols.push(c.name)
  }
  s
}

///|
/// The `Table` descriptor for this model (name + column names), for interop with
/// the plain builder API.
pub fn[T] Model::table_descriptor(self : Model[T]) -> @query.Table {
  { name: self.table, columns: self.column_names(), }
}

///|
/// Render `CREATE TABLE` DDL for this model from its declared columns. With
/// `if_not_exists=true` the statement is idempotent (`CREATE TABLE IF NOT EXISTS`).
/// This is the explicit counterpart of SQLAlchemy's `metadata.create_all()`.
pub fn[T] Model::create_table_sql(
  self : Model[T],
  if_not_exists~ : Bool = false,
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
    defs.push("PRIMARY KEY (" + pks.map(fn(c) { c.name }).join(", ") + ")")
  }
  head + self.table + " (" + defs.join(", ") + ")"
}

///|
/// Build an `Insert` that persists `record`, binding the pairs from `to_columns`.
/// Values travel as `?` placeholders exactly like the rest of the builder.
pub fn[T] Model::insert_of(self : Model[T], record : T) -> @query.Insert {
  let mut ins = @query.insert(self.table)
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
/// `CREATE TABLE` DDL for this model rendered for a specific `Dialect` — the
/// multi-dialect counterpart of `create_table_sql`. Uses `Column::ddl_for`, keeps a
/// composite primary key as a table-level constraint, and appends `ENGINE=InnoDB` on
/// MySQL.
pub fn[T] Model::create_table_sql_for(
  self : Model[T],
  dialect : @query.Dialect,
  if_not_exists~ : Bool = false,
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
    defs.push("PRIMARY KEY (" + pks.map(fn(c) { c.name }).join(", ") + ")")
  }
  let tail = if dialect is Mysql { " ENGINE=InnoDB" } else { "" }
  head + self.table + " (" + defs.join(", ") + ")" + tail
}
