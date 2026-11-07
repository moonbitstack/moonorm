// The asynchronous unit of work: the same queues, identity map and flush as
// `Session`, with each rendered statement awaited. The ordering and the identity
// rules are `Core`'s, so they cannot drift from the synchronous twin's.

///|
/// Fetch by primary key, consulting the identity map before the database — the awaited
/// [`Session::get`]. A record this session already holds costs no round trip.
pub async fn[T] AsyncSession::get(
  self : AsyncSession,
  model : @schema.Model[T],
  pk : @moondb.Value,
) -> T? raise @moondb.DbError {
  self.get_by(model, [pk])
}

///|
/// `get` for a composite primary key: one value per declared key column, in
/// declaration order.
pub async fn[T] AsyncSession::get_by(
  self : AsyncSession,
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
/// Queue `record` for insertion — the awaited [`Session::add_record`]: nothing
/// reaches the database until `flush` or `commit`.
pub fn[T] AsyncSession::add_record(
  self : AsyncSession,
  model : @schema.Model[T],
  record : T,
) -> Unit {
  self.core.enqueue_insert(self.dialect, model, record)
}

///|
/// Queue every record in `records` for insertion.
pub fn[T] AsyncSession::add_all(
  self : AsyncSession,
  model : @schema.Model[T],
  records : Array[T],
) -> Unit {
  for record in records {
    self.core.enqueue_insert(self.dialect, model, record)
  }
}

///|
/// Queue `record`'s current state as an `UPDATE` keyed on its primary key.
pub fn[T] AsyncSession::update_record(
  self : AsyncSession,
  model : @schema.Model[T],
  record : T,
) -> Unit raise @moondb.DbError {
  self.core.enqueue_update(self.dialect, model, record)
}

///|
/// Queue `record` for deletion, keyed on its primary key.
pub fn[T] AsyncSession::delete_record(
  self : AsyncSession,
  model : @schema.Model[T],
  record : T,
) -> Unit raise @moondb.DbError {
  self.core.enqueue_delete(self.dialect, model, record)
}

///|
/// Queue every record in `records` for deletion.
pub fn[T] AsyncSession::delete_all(
  self : AsyncSession,
  model : @schema.Model[T],
  records : Array[T],
) -> Unit raise @moondb.DbError {
  for record in records {
    self.core.enqueue_delete(self.dialect, model, record)
  }
}

///|
/// Insert `record` or update it, whichever its primary key calls for — the awaited
/// [`Session::merge`]. The lookup is a round trip, so `merge` is one statement
/// dearer than `add_record` on a row that may exist.
pub async fn[T] AsyncSession::merge(
  self : AsyncSession,
  model : @schema.Model[T],
  record : T,
) -> T {
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
/// Re-read `record`'s row and replace it in the identity map — the awaited
/// [`Session::refresh`]. Raises [`LostUpdate`] when the row is gone.
pub async fn[T] AsyncSession::refresh(
  self : AsyncSession,
  model : @schema.Model[T],
  record : T,
) -> T {
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
/// Emit every queued statement in dependency order: inserts, then updates, then
/// deletes in reverse. Nothing here commits.
pub async fn AsyncSession::flush(
  self : AsyncSession,
) -> Unit raise @moondb.DbError {
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
/// Render one queued write, fire its hooks around it, await its statements and settle
/// its identity bookkeeping.
async fn AsyncSession::run(
  self : AsyncSession,
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
/// How many records are queued for insertion.
pub fn AsyncSession::pending_count(self : AsyncSession) -> Int32 {
  self.core.pending.length()
}

///|
/// How many records are queued for update.
pub fn AsyncSession::dirty_count(self : AsyncSession) -> Int32 {
  self.core.dirty.length()
}

///|
/// How many records are queued for deletion.
pub fn AsyncSession::deleted_count(self : AsyncSession) -> Int32 {
  self.core.deleted.length()
}

///|
/// Drop `record` from the identity map, so the next `get` reads the row back.
pub fn[T] AsyncSession::expunge(
  self : AsyncSession,
  model : @schema.Model[T],
  record : T,
) -> Unit {
  self.core.forget(model, record)
}

///|
/// Empty the identity map.
pub fn AsyncSession::expunge_all(self : AsyncSession) -> Unit {
  self.core.expunge_all()
}

///|
/// Mark every loaded record stale, so the next `get` reads it back.
pub fn AsyncSession::expire_all(self : AsyncSession) -> Unit {
  self.core.expunge_all()
}
