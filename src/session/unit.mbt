// The unit of work: an identity map, the pending/dirty/deleted queues, and the
// flush that turns them into ordered SQL. SQLAlchemy builds this on attribute
// interception — loading a row registers the instance, touching an attribute marks
// it dirty, and `Session.flush` sorts the whole graph by mapper dependency. MoonBit
// has neither interception nor reflection, so both halves are declared instead: the
// key comes from the `Model`'s primary-key columns, and a changed record is one the
// caller hands to `update_record`. The ordering, the identity, and the single flush
// boundary are the same.
//
// The bookkeeping lives in `Core`, which `AsyncSession` drives too; only the
// statement that reaches the server differs between the two.

///|
/// Fetch by primary key, consulting the identity map before the database —
/// SQLAlchemy's `Session.get`. A row this session has already loaded comes back as
/// the *same* record instance and costs no query; anything else is a
/// `SELECT … WHERE pk = ? LIMIT 1` whose result is decoded once and kept. `None`
/// means there is no such row.
///
/// Because the instance is shared, a record with mutable fields is shared too: two
/// holders of the same row see each other's writes, which is the point of an identity
/// map. `expunge` drops one; `get_by` takes a composite key.
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
  let (sql, params) = key_query(model, key)
  match self.core.lookup(model, key) {
    Some(hit) => Some(hit)
    None => {
      let rows = self.driver.query(sql, params)
      self.core.adopt(model, key, rows)
    }
  }
}

///|
/// The identity-map key a `get` would look under, and the statement to run when it is
/// a miss — the two halves every read-by-key shares.
fn[T] key_query(
  model : @schema.Model[T],
  key : Array[@moondb.Value],
) -> (String, Array[@moondb.Value]) raise @moondb.DbError {
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
  let mut stmt = model.select()
  for i in 0..<cols.length() {
    stmt = stmt.where_(cols[i], "=", key[i])
  }
  stmt.limit(1).build()
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
  self.core.enqueue_insert(self.dialect, model, record)
}

///|
/// Queue every record in `records` for insertion — SQLAlchemy's `Session.add_all`.
/// One flush writes them in dependency order, so a parent added after its child still
/// goes first.
pub fn[T] Session::add_all(
  self : Session,
  model : @schema.Model[T],
  records : Array[T],
) -> Unit {
  for record in records {
    self.core.enqueue_insert(self.dialect, model, record)
  }
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
  self.core.enqueue_update(self.dialect, model, record)
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
  self.core.enqueue_delete(self.dialect, model, record)
}

///|
/// Queue every record in `records` for deletion — SQLAlchemy's `Session.delete_all`.
/// They are removed in reverse dependency order at the next flush.
pub fn[T] Session::delete_all(
  self : Session,
  model : @schema.Model[T],
  records : Array[T],
) -> Unit raise @moondb.DbError {
  for record in records {
    self.core.enqueue_delete(self.dialect, model, record)
  }
}

///|
/// Insert `record` or update it, whichever its primary key calls for — SQLAlchemy's
/// `Session.merge`, less the detached-instance copying: MoonBit records are values, so
/// there is nothing to re-attach and the returned record is the one put in the
/// identity map.
///
/// A record whose key the identity map already holds, or whose row the database
/// already has, is queued as an `UPDATE`; anything else is queued as an `INSERT`. The
/// lookup runs now, so `merge` costs one `SELECT` on a miss and none on a hit. The
/// queue, not this call, decides when the write happens — `flush` or `commit`.
pub fn[T] Session::merge(
  self : Session,
  model : @schema.Model[T],
  record : T,
) -> T raise {
  let key = record_key(model, record)
  let known = match self.core.lookup(model, key) {
    Some(_) => true
    None => {
      let (sql, params) = key_query(model, key)
      self.driver.query(sql, params).length() > 0
    }
  }
  if known {
    self.core.enqueue_update(self.dialect, model, record)
  } else {
    self.core.enqueue_insert(self.dialect, model, record)
  }
  record
}

///|
/// Re-read `record`'s row and replace it in the identity map — SQLAlchemy's
/// `Session.refresh`. It is what a caller reaches for after a savepoint rollback or a
/// trigger changed the row behind its back.
///
/// Raises `QueryError` when the record carries no primary key, and `LostUpdate` when
/// the row is gone: a refresh that silently returned the stale record would be worse
/// than one that says the row is no longer there.
pub fn[T] Session::refresh(
  self : Session,
  model : @schema.Model[T],
  record : T,
) -> T raise {
  let key = record_key(model, record)
  let (sql, params) = key_query(model, key)
  let rows = self.driver.query(sql, params)
  if rows.length() == 0 {
    raise LostUpdate(model.table + ": the row to refresh is gone")
  }
  let fresh = model.map_row(rows[0])
  self.core.remember(model, fresh)
  fresh
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
  defer self.core.sweep()
  self.core.fire(HookContext::new(BeforeFlush))
  for w in plan(self.core.pending) {
    self.run(w, BeforeInsert, AfterInsert)
  }
  for w in self.core.dirty {
    self.run(w, BeforeUpdate, AfterUpdate)
  }
  let order = plan(self.core.deleted)
  for i = order.length() - 1; i >= 0; i = i - 1 {
    self.run(order[i], BeforeDelete, AfterDelete)
  }
  self.core.fire(HookContext::new(AfterFlush))
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
  self.core.fire(ctx)
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
  self.core.fire(done)
  (w.settle)()
  w.done = true
}

///|
/// How many records are queued for insertion — SQLAlchemy's `Session.new`.
pub fn Session::pending_count(self : Session) -> Int32 {
  self.core.pending.length()
}

///|
/// How many records are queued for update — SQLAlchemy's `Session.dirty`.
pub fn Session::dirty_count(self : Session) -> Int32 {
  self.core.dirty.length()
}

///|
/// How many records are queued for deletion — SQLAlchemy's `Session.deleted`.
pub fn Session::deleted_count(self : Session) -> Int32 {
  self.core.deleted.length()
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
  self.core.forget(model, record)
}

///|
/// Empty the identity map: every model this session has loaded through forgets it.
/// SQLAlchemy's `Session.expunge_all`.
pub fn Session::expunge_all(self : Session) -> Unit {
  self.core.expunge_all()
}

///|
/// Mark every loaded record stale, SQLAlchemy's `Session.expire_all`: the next `get`
/// reads the row back instead of handing out the copy this session kept. MoonBit
/// records are read through a call, not an attribute, so expiring eagerly here and
/// reloading lazily there come to the same thing — both drop the copy.
pub fn Session::expire_all(self : Session) -> Unit {
  self.core.expunge_all()
}
