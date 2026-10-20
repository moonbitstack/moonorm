// The unit of work: an identity map, the pending/dirty/deleted queues, and the
// flush that turns them into ordered SQL. SQLAlchemy builds this on attribute
// interception — loading a row registers the instance, touching an attribute marks
// it dirty, and `Session.flush` sorts the whole graph by mapper dependency. MoonBit
// has neither interception nor reflection, so both halves are declared instead: the
// key comes from the `Model`'s primary-key columns, and a changed record is one the
// caller hands to `update_record`. The ordering, the identity, and the single flush
// boundary are the same.

///|
/// One queued statement: the table it writes, the tables that must be written before
/// it, the thunk that renders it at flush time, and the identity bookkeeping to run
/// once it has executed.
struct Work {
  table : String
  parents : Array[String]
  emit : () -> (String, Array[Value])
  settle : () -> Unit
  mut done : Bool
}

///|
/// One primary-key value rendered into an identity-map key. Integer widths and
/// booleans collapse to one spelling, because a key bound as `Int(1)` has to find the
/// row a backend handed back as `Int64(1)`. Text and blobs carry their length, so no
/// two distinct keys can spell the same string.
fn key_part(v : Value) -> String {
  match v {
    Null => "z"
    Bool(b) => "i" + (if b { "1" } else { "0" })
    Int(n) => "i" + n.to_string()
    Int64(n) => "i" + n.to_string()
    Double(d) => "d" + d.to_string()
    Text(s) => "s" + s.length().to_string() + ":" + s
    Blob(b) => {
      // Decimal per byte rather than hex: a binary key is rare enough that the
      // shorter spelling is not worth a digit table.
      let mut s = "b" + b.length().to_string() + ":"
      for i in 0..<b.length() {
        s = s + b[i].to_int().to_string() + "."
      }
      s
    }
  }
}

///|
/// The identity-map key for a whole (possibly composite) primary key.
fn identity_key(key : Array[Value]) -> String {
  let parts : Array[String] = []
  for v in key {
    parts.push(key_part(v))
  }
  join(parts, "|")
}

///|
/// A record's primary key, or a `QueryError` naming what is missing. Addressing an
/// existing row needs the key, and MoonBit cannot discover it: it comes from the
/// model's declared key columns and that model's own value projection.
fn[T] record_key(
  model : Model[T],
  record : T,
) -> Array[Value] raise @moondb.DbError {
  let cols = model.pk_columns()
  if cols.length() == 0 {
    raise @moondb.QueryError(model.table + " declares no primary key")
  }
  let key = model.pk_of(record)
  if key.length() != cols.length() {
    raise @moondb.QueryError(
      model.table +
      ": record carries no value for primary key " +
      join(cols, ", "),
    )
  }
  key
}

///|
/// This session's slot in `model`'s identity map, created on first use and
/// registered for teardown so `expunge_all` can drop it again.
fn[T] Session::slot(self : Session, model : Model[T]) -> Map[String, T] {
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
fn[T] Session::remember(self : Session, model : Model[T], record : T) -> Unit {
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
  model : Model[T],
  pk : Value,
) -> T? raise @moondb.DbError {
  self.get_by(model, [pk])
}

///|
/// `get` for a composite primary key: one value per declared key column, in
/// declaration order. Raises `QueryError` when the model declares no primary key, or
/// when `key` is not as wide as the one it declares.
pub fn[T] Session::get_by(
  self : Session,
  model : Model[T],
  key : Array[Value],
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
  model : Model[T],
  record : T,
) -> Unit {
  self.pending.push({
    table: model.table,
    parents: model.parent_tables(),
    emit: () => model.insert_of(record).build(),
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
  model : Model[T],
  record : T,
) -> Unit raise @moondb.DbError {
  let key = record_key(model, record)
  let cols = model.pk_columns()
  let mut stmt = update(model.table)
  let mut sets = 0
  for pair in (model.to_columns)(record) {
    if !cols.contains(pair.0) {
      stmt = stmt.set(pair.0, pair.1)
      sets = sets + 1
    }
  }
  if sets == 0 {
    raise @moondb.QueryError(
      model.table +
      ": every column belongs to the primary key, nothing to update",
    )
  }
  for i in 0..<cols.length() {
    stmt = stmt.where_(cols[i], "=", key[i])
  }
  // A closure cannot capture a `mut` binding, so freeze the finished statement.
  let q = stmt
  self.dirty.push({
    table: model.table,
    parents: model.parent_tables(),
    emit: () => q.build(),
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
  model : Model[T],
  record : T,
) -> Unit raise @moondb.DbError {
  let key = record_key(model, record)
  let cols = model.pk_columns()
  let mut stmt = delete(model.table)
  for i in 0..<cols.length() {
    stmt = stmt.where_(cols[i], "=", key[i])
  }
  // A closure cannot capture a `mut` binding, so freeze the finished statement.
  let q = stmt
  self.deleted.push({
    table: model.table,
    parents: model.parent_tables(),
    emit: () => q.build(),
    settle: () => self.slot(model).remove(identity_key(key)),
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
/// Render one queued statement, run it, and settle its identity bookkeeping.
fn Session::run(self : Session, w : Work) -> Unit raise @moondb.DbError {
  let (sql, params) = (w.emit)()
  self.driver.execute(sql, params) |> ignore
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
/// A statement that has run leaves the queue even when a later one raises, so the
/// failed flush can be rolled back without replaying what already executed.
pub fn Session::flush(self : Session) -> Unit raise @moondb.DbError {
  defer self.sweep()
  for w in plan(self.pending) {
    self.run(w)
  }
  for w in self.dirty {
    self.run(w)
  }
  let order = plan(self.deleted)
  for i = order.length() - 1; i >= 0; i = i - 1 {
    self.run(order[i])
  }
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
  model : Model[T],
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
