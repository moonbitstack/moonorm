// The unit of work: an identity map, the pending/dirty/deleted queues, and the
// flush that turns them into ordered SQL. SQLAlchemy builds this on attribute
// interception — loading a row registers the instance, touching an attribute marks
// it dirty, and `Session.flush` sorts the whole graph by mapper dependency. MoonBit
// has neither interception nor reflection, so both halves are declared instead: the
// key comes from the `Model`'s primary-key columns, and a changed record is one the
// caller hands to `update_record`. The ordering, the identity, and the single flush
// boundary are the same.

///|
/// One queued write: the table it writes, the tables that must be written before it,
/// how to read the row's current columns, how to render the statements for those
/// columns, and the identity bookkeeping to run once they have executed.
///
/// The columns are re-read at flush time rather than captured at queue time, so the
/// row written is the record's state at the flush — and so a `Before*` hook can
/// rewrite it and have the statement follow.
struct Work {
  table : String
  parents : Array[String]
  columns : () -> Array[(String, @moondb.Value)]
  emit : (Array[(String, @moondb.Value)]) -> Array[
    (String, Array[@moondb.Value]),
  ]
  settle : () -> Unit
  mut done : Bool
}

///|
/// One primary-key value rendered into an identity-map key. Integer widths and
/// booleans collapse to one spelling, because a key bound as `Int(1)` has to find the
/// row a backend handed back as `Int64(1)`. Text and blobs carry their length, so no
/// two distinct keys can spell the same string.
fn key_part(v : @moondb.Value) -> String {
  match v {
    Null => "z"
    Bool(b) => "i" + (if b { "1" } else { "0" })
    Int(n) => "i" + n.to_string()
    Int64(n) => "i" + n.to_string()
    Double(d) => "d" + d.to_string()
    Text(s) => sized_part("s", s)
    Time(s) => sized_part("t", s)
    Numeric(s) => sized_part("n", s)
    Json(s) => sized_part("j", s)
    Blob(b) => bytes_part("b", b)
    Uuid(b) => bytes_part("u", b)
    Array(items) => {
      let mut s = "a" + items.length().to_string() + ":"
      for item in items {
        s = s + key_part(item) + ";"
      }
      s
    }
  }
}

///|
fn sized_part(tag : String, s : String) -> String {
  tag + s.length().to_string() + ":" + s
}

///|
/// Decimal per byte rather than hex: a binary key is rare enough that the shorter spelling is not
/// worth a digit table.
fn bytes_part(tag : String, b : Bytes) -> String {
  let mut s = tag + b.length().to_string() + ":"
  for i in 0..<b.length() {
    s = s + b[i].to_int().to_string() + "."
  }
  s
}

///|
/// The identity-map key for a whole (possibly composite) primary key.
fn identity_key(key : Array[@moondb.Value]) -> String {
  let parts : Array[String] = []
  for v in key {
    parts.push(key_part(v))
  }
  parts.join("|")
}

///|
/// A record's primary key, or a `QueryError` naming what is missing. Addressing an
/// existing row needs the key, and MoonBit cannot discover it: it comes from the
/// model's declared key columns and that model's own value projection.
fn[T] record_key(
  model : @schema.Model[T],
  record : T,
) -> Array[@moondb.Value] raise @moondb.DbError {
  let cols = model.pk_columns()
  if cols.length() == 0 {
    raise @moondb.QueryError(model.table + " declares no primary key")
  }
  let key = model.pk_of(record)
  if key.length() != cols.length() {
    raise @moondb.QueryError(
      model.table +
      ": record carries no value for primary key " +
      cols.join(", "),
    )
  }
  key
}

///|
/// The columns that address a row of `table` for this model: the primary key for a
/// plain model, the parent key in the parent table of a joined mapping, and the
/// foreign key in the subclass table.
fn[T] key_columns_of(model : @schema.Model[T], table : String) -> Array[String] {
  if !model.is_joined() {
    model.pk_columns()
  } else if table == model.parent_table() {
    [model.parent_key()]
  } else {
    [model.parent_fk()]
  }
}

///|
/// Render one INSERT per table the row is written to, parent first — the order a
/// foreign key requires.
fn insert_statements(
  rows : Array[(String, Array[(String, @moondb.Value)])],
  dialect : @query.Dialect,
) -> Array[(String, Array[@moondb.Value])] {
  let out : Array[(String, Array[@moondb.Value])] = []
  for row in rows {
    let (table, pairs) = row
    if pairs.length() == 0 {
      continue
    }
    let mut ins = @query.insert(table)
    for pair in pairs {
      ins = ins.set(pair.0, pair.1)
    }
    out.push(ins.build_for(dialect))
  }
  out
}

///|
/// Render one UPDATE per table the row spans, setting every non-key column and
/// addressing the row by that table's key.
fn[T] update_statements(
  model : @schema.Model[T],
  columns : Array[(String, @moondb.Value)],
  dialect : @query.Dialect,
) -> Array[(String, Array[@moondb.Value])] {
  let out : Array[(String, Array[@moondb.Value])] = []
  for group in model.split_columns(columns) {
    let (table, pairs) = group
    let keys = key_columns_of(model, table)
    let mut stmt = @query.update(table)
    let mut sets = 0
    for pair in pairs {
      if !keys.contains(pair.0) {
        stmt = stmt.set(pair.0, pair.1)
        sets = sets + 1
      }
    }
    if sets == 0 {
      continue
    }
    for key in keys {
      for pair in pairs {
        if pair.0 == key {
          stmt = stmt.where_(pair.0, "=", pair.1)
        }
      }
    }
    out.push(stmt.build_for(dialect))
  }
  out
}

///|
/// Render one DELETE per table the row spans, subclass first — the reverse of the
/// order an insert takes, so the row holding the foreign key goes before the one it
/// points at.
fn[T] delete_statements(
  model : @schema.Model[T],
  columns : Array[(String, @moondb.Value)],
  dialect : @query.Dialect,
) -> Array[(String, Array[@moondb.Value])] {
  let groups = model.split_columns(columns)
  let out : Array[(String, Array[@moondb.Value])] = []
  for i = groups.length() - 1; i >= 0; i = i - 1 {
    let (table, pairs) = groups[i]
    let keys = key_columns_of(model, table)
    let mut stmt = @query.delete(table)
    let mut matched = 0
    for key in keys {
      for pair in pairs {
        if pair.0 == key {
          stmt = stmt.where_(pair.0, "=", pair.1)
          matched = matched + 1
        }
      }
    }
    if matched > 0 {
      out.push(stmt.build_for(dialect))
    }
  }
  out
}

///|
/// This session's slot in `model`'s identity map, created on first use and
/// registered for teardown so `expunge_all` can drop it again.
fn[T] Session::slot(self : Session, model : @schema.Model[T]) -> Map[String, T] {
  match model.ident.get(self.id) {
    Some(m) => m
    None => {
      let m : Map[String, T] = Map([])
      model.ident.set(self.id, m)
      self.detach.push(() => model.ident.remove(self.id))
      m
    }
  }
}

///|
/// Put `record` in the identity map under its primary key. A record whose key the
/// model's projection does not carry — an autoincrement id the server assigns — stays
/// unidentified, so a later `get` reads it back from the database instead of handing
/// out a half-known instance.
fn[T] Session::remember(
  self : Session,
  model : @schema.Model[T],
  record : T,
) -> Unit {
  let key = model.pk_of(record)
  if key.length() > 0 && key.length() == model.pk_columns().length() {
    self.slot(model).set(identity_key(key), record)
  }
}

///|
/// Fetch by primary key, consulting the identity map before the database —
/// SQLAlchemy's `Session.get`. A row this session has already loaded comes back as
/// the *same* record instance and costs no query; anything else is a
/// `SELECT … WHERE pk = ? LIMIT 1` whose result is decoded once and kept. `None`
/// means there is no such row.
///
/// Because the instance is shared, a record with mutable fields is shared too: two
/// holders of the same row see each other's writes, which is the point of an
/// identity map. `expunge` drops one; `get_by` takes a composite key.
///
/// The map is scoped to this session *and* to the `Model` value passed in, so keep
/// the model in a `let` — one rebuilt on every call is a new descriptor each time and
/// carries no history.
pub fn[T] Session::get(
  self : Session,
  model : @schema.Model[T],
  pk : @moondb.Value,
) -> T? raise @moondb.DbError {
  self.get_by(model, [pk])
}

///|
/// `get` for a composite primary key: one value per declared key column, in
/// declaration order. Raises `QueryError` when the model declares no primary key, or
/// when `key` is not as wide as the one it declares.
pub fn[T] Session::get_by(
  self : Session,
  model : @schema.Model[T],
  key : Array[@moondb.Value],
) -> T? raise @moondb.DbError {
  let cols = model.pk_columns()
  if cols.length() == 0 {
    raise @moondb.QueryError(model.table + " declares no primary key")
  }
  if cols.length() != key.length() {
    raise @moondb.QueryError(
      model.table +
      " has a " +
      cols.length().to_string() +
      "-column primary key, given " +
      key.length().to_string(),
    )
  }
  let slot = self.slot(model)
  let k = identity_key(key)
  if slot.get(k) is Some(hit) {
    return Some(hit)
  }
  let mut stmt = model.select()
  for i in 0..<cols.length() {
    stmt = stmt.where_(cols[i], "=", key[i])
  }
  let (sql, params) = stmt.limit(1).build()
  let rows = self.driver.query(sql, params)
  if rows.length() == 0 {
    return None
  }
  let record = model.map_row(rows[0])
  slot.set(k, record)
  Some(record)
}

///|
/// Queue `record` for insertion — SQLAlchemy's `Session.add`. Nothing reaches the
/// database until `flush`, or until `commit` flushes on the caller's behalf; the
/// delay is what lets the flush order parents before children and register the row in
/// the identity map. To insert on this call instead, use `insert_record`.
pub fn[T] Session::add_record(
  self : Session,
  model : @schema.Model[T],
  record : T,
) -> Unit {
  let dialect = self.dialect
  self.pending.push({
    table: model.table,
    parents: model.parent_tables(),
    columns: () => (model.to_columns)(record),
    emit: columns => insert_statements(model.split_columns(columns), dialect),
    settle: () => self.remember(model, record),
    done: false,
  })
}

///|
/// Queue `record`'s current state as an `UPDATE` keyed on its primary key — the
/// explicit stand-in for SQLAlchemy's dirty tracking, which notices a change by
/// instrumenting attribute writes. MoonBit intercepts nothing, so a changed record is
/// one the caller says is changed. The statement sets every non-key column, is
/// emitted after the inserts, and refreshes the identity map.
///
/// Raises `QueryError` when the model declares no primary key, when the record does
/// not carry one, or when every column belongs to the key and there is nothing to
/// set. To update on this call instead, build an `Update` and use `modify`.
pub fn[T] Session::update_record(
  self : Session,
  model : @schema.Model[T],
  record : T,
) -> Unit raise @moondb.DbError {
  // Addressability is checked now, so a record without a key fails at the call that
  // queued it rather than halfway through a flush.
  record_key(model, record) |> ignore
  let cols = model.pk_columns()
  let mut sets = 0
  for pair in (model.to_columns)(record) {
    if !cols.contains(pair.0) {
      sets = sets + 1
    }
  }
  if sets == 0 {
    raise @moondb.QueryError(
      model.table +
      ": every column belongs to the primary key, nothing to update",
    )
  }
  let dialect = self.dialect
  self.dirty.push({
    table: model.table,
    parents: model.parent_tables(),
    columns: () => (model.to_columns)(record),
    emit: columns => update_statements(model, columns, dialect),
    settle: () => self.remember(model, record),
    done: false,
  })
}

///|
/// Queue `record` for deletion — SQLAlchemy's `Session.delete`. The `DELETE` is keyed
/// on the record's primary key and runs last, in the reverse dependency order, so a
/// child row goes before the parent it points at. Flushing it also drops the record
/// from the identity map.
///
/// Raises `QueryError` when the model declares no primary key or the record does not
/// carry one. To delete on this call instead, build a `Delete` and use `remove`.
pub fn[T] Session::delete_record(
  self : Session,
  model : @schema.Model[T],
  record : T,
) -> Unit raise @moondb.DbError {
  let key = record_key(model, record)
  let dialect = self.dialect
  let identity = identity_key(key)
  self.deleted.push({
    table: model.table,
    parents: model.parent_tables(),
    columns: () => (model.to_columns)(record),
    emit: columns => delete_statements(model, columns, dialect),
    settle: () => self.slot(model).remove(identity),
    done: false,
  })
}

///|
/// Queued inserts in dependency order: a row is emitted only once every table it
/// references has been, so a parent precedes its children. The order is stable —
/// among rows with nothing left to wait for, the one queued first goes first — which
/// keeps two unrelated tables in the order the caller added them. A reference cycle
/// admits no valid order, so the rest falls back to queue order rather than spinning.
fn plan(work : Array[Work]) -> Array[Work] {
  let out : Array[Work] = []
  let left = work.copy()
  while left.length() > 0 {
    let mut pick = 0
    for i = 0; i < left.length(); i = i + 1 {
      if ready(left[i], left, i) {
        pick = i
        break
      }
    }
    out.push(left.remove(pick))
  }
  out
}

///|
/// Whether nothing still queued has to be written before `w`, which sits at `at`.
fn ready(w : Work, left : Array[Work], at : Int32) -> Bool {
  for i = 0; i < left.length(); i = i + 1 {
    if i == at {
      continue
    }
    for p in w.parents {
      if left[i].table == p {
        return false
      }
    }
  }
  true
}

///|
/// Render one queued write, fire its hooks around it, run its statements, and settle
/// its identity bookkeeping.
///
/// The row's columns are read first, so a `Before*` listener sees what is about to be
/// written and can rewrite it. The `After*` listener is handed a statement that ran
/// — the last one, when a joined mapping wrote two — so it can log what reached the
/// database.
fn Session::run(
  self : Session,
  w : Work,
  before : HookEvent,
  after : HookEvent,
) -> Unit raise @moondb.DbError {
  let ctx = HookContext::new(before, table=w.table, columns=(w.columns)())
  self.fire(ctx)
  let statements = (w.emit)(ctx.columns)
  let mut last_sql = ""
  let mut last_params : Array[@moondb.Value] = []
  for statement in statements {
    let (sql, params) = statement
    self.driver.execute(sql, params) |> ignore
    last_sql = sql
    last_params = params
  }
  let done = HookContext::new(after, table=w.table, columns=ctx.columns)
  done.sql = last_sql
  done.params = last_params
  self.fire(done)
  (w.settle)()
  w.done = true
}

///|
/// Forget the statements that executed, keeping whatever a failed flush never
/// reached.
fn Session::sweep(self : Session) -> Unit {
  self.pending.retain(w => !w.done)
  self.dirty.retain(w => !w.done)
  self.deleted.retain(w => !w.done)
}

///|
/// Emit every queued statement — SQLAlchemy's `Session.flush`, the point where the
/// unit of work becomes SQL. Inserts go first in dependency order, so a parent row
/// precedes any child that references it; then the updates; then the deletes in the
/// reverse order, so a child goes before its parent. Nothing here commits.
///
/// `BeforeFlush` runs once before the first statement and `AfterFlush` once after the
/// last, which is where a listener that wants to see the whole batch registers.
///
/// A statement that has run leaves the queue even when a later one raises, so the
/// failed flush can be rolled back without replaying what already executed.
pub fn Session::flush(self : Session) -> Unit raise @moondb.DbError {
  defer self.sweep()
  self.fire(HookContext::new(BeforeFlush))
  for w in plan(self.pending) {
    self.run(w, BeforeInsert, AfterInsert)
  }
  for w in self.dirty {
    self.run(w, BeforeUpdate, AfterUpdate)
  }
  let order = plan(self.deleted)
  for i = order.length() - 1; i >= 0; i = i - 1 {
    self.run(order[i], BeforeDelete, AfterDelete)
  }
  self.fire(HookContext::new(AfterFlush))
}

///|
/// How many records are queued for insertion — SQLAlchemy's `Session.new`.
pub fn Session::pending_count(self : Session) -> Int32 {
  self.pending.length()
}

///|
/// How many records are queued for update — SQLAlchemy's `Session.dirty`.
pub fn Session::dirty_count(self : Session) -> Int32 {
  self.dirty.length()
}

///|
/// How many records are queued for deletion — SQLAlchemy's `Session.deleted`.
pub fn Session::deleted_count(self : Session) -> Int32 {
  self.deleted.length()
}

///|
/// Drop `record` from the identity map, so the next `get` reads the row back from the
/// database and returns a fresh instance. SQLAlchemy's `Session.expunge`. Queued work
/// for the record is left alone.
pub fn[T] Session::expunge(
  self : Session,
  model : @schema.Model[T],
  record : T,
) -> Unit {
  let key = model.pk_of(record)
  if key.length() > 0 && key.length() == model.pk_columns().length() {
    self.slot(model).remove(identity_key(key))
  }
}

///|
/// Empty the identity map: every model this session has loaded through forgets it.
/// SQLAlchemy's `Session.expunge_all`.
pub fn Session::expunge_all(self : Session) -> Unit {
  for drop in self.detach {
    drop()
  }
  self.detach.clear()
}

///|
/// Abandon everything queued and forget every record loaded.
fn Session::discard(self : Session) -> Unit {
  self.pending.clear()
  self.dirty.clear()
  self.deleted.clear()
  self.expunge_all()
}
