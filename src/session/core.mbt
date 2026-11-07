// The state a unit of work carries, and the bookkeeping only the session can do:
// the pending/dirty/deleted queues, the identity-map slots, the savepoint marks and
// the connection-level statements a transaction switched on. It is kept out of
// `Session` and `AsyncSession` so both drive the same state — the two differ only in
// how a rendered statement reaches the server, so the ordering, the identity map and
// the rollback rules cannot drift between them.

///|
/// One queued write: the table it writes, the tables that must be written before it,
/// how to read the row's current columns, how to render the statements for those
/// columns, and the identity bookkeeping to run once they have executed.
///
/// The columns are re-read at flush time rather than captured at queue time, so the
/// row written is the record's state at the flush — and so a `Before*` hook can
/// rewrite it and have the statement follow.
///
/// `seq` is the session's queue serial at the moment the write was queued. A savepoint
/// remembers the serial it opened at, which is how a rollback to it finds the writes
/// that came after — including the ones a released nested savepoint folded in — without
/// depending on where they sit in the array, since a flush removes what it executed.
priv struct Work {
  table : String
  parents : Array[String]
  seq : Int32
  columns : () -> Array[(String, @moondb.Value)]
  emit : (Array[(String, @moondb.Value)]) -> Array[
    (String, Array[@moondb.Value]),
  ]
  settle : () -> Unit
  mut done : Bool
}

///|
/// A savepoint the session opened, as the session remembers it: the queue serial it
/// opened at, and how to put every identity map back the way it was. A rollback to the
/// savepoint drops the writes queued after that serial and restores these maps, so the
/// records a caller can reach describe rows the database still has.
priv struct Mark {
  name : String
  seq : Int32
  restore : Array[() -> Unit]
  // How many identity maps existed when the savepoint opened. A map created after it
  // holds only rows the rollback undoes, so it is dropped rather than restored.
  slots : Int32
}

///|
/// One model's identity slot, as the session can revisit it: take a copy and hand back
/// the closure that puts the copy back, or drop the slot outright.
priv struct SlotReset {
  snapshot : () -> () -> Unit
  drop : () -> Unit
}

///|
/// The state both session types carry. `id` names this session's slot in the identity
/// map of every model it touches.
struct Core {
  // `sp_seq` only ever increases, giving each savepoint a name unique within the
  // session even after earlier ones are released. The open savepoints themselves are
  // `marks`, so their count is the depth.
  mut sp_seq : Int32
  // The queue serial: bumped for every queued write, so a savepoint can be told apart
  // from the writes that follow it.
  mut work_seq : Int32
  id : Int32
  pending : Array[Work]
  dirty : Array[Work]
  deleted : Array[Work]
  // Drops this session's identity slot out of each model it claimed one in. A model
  // is normally a long-lived top-level value, so nothing else would ever free it.
  detach : Array[() -> Unit]
  // One per model this session has touched: take a copy of that model's identity slot
  // and hand back the closure that puts the copy back. A savepoint calls this when it
  // opens, which is what lets a rollback restore the records as they were.
  snapshots : Array[SlotReset]
  marks : Array[Mark]
  // Statements that undo connection-level transaction options (`PRAGMA query_only`),
  // run when the transaction that set them ends. They outlive the transaction on the
  // connection otherwise, which would leave the next transaction on the pooled
  // connection unable to write.
  mut restore : Array[String]
  // Event listeners, in registration order (see `Session::on`).
  hooks : Array[(HookEvent, (HookContext) -> Unit raise @moondb.DbError)]
}

///|
/// Session serials. Identity maps live in the models rather than the session, so a
/// session needs a name no other live session shares. The counter is shared by both
/// session types: an async and a synchronous session over the same model must not
/// claim the same slot.
let session_seq : Ref[Int32] = Ref(0)

///|
/// An empty unit of work, with its own identity-map key.
fn Core::new() -> Core {
  session_seq.val = session_seq.val + 1
  {
    sp_seq: 0,
    work_seq: 0,
    id: session_seq.val,
    pending: [],
    dirty: [],
    deleted: [],
    detach: [],
    snapshots: [],
    marks: [],
    restore: [],
    hooks: [],
  }
}

///|
/// The next queue serial.
fn Core::next_seq(self : Core) -> Int32 {
  self.work_seq = self.work_seq + 1
  self.work_seq
}

///|
/// Remember that a savepoint `name` opened now, taking a copy of every identity map
/// this session holds. A later rollback to it restores those copies.
fn Core::open_mark(self : Core, name : String) -> Unit {
  let restore : Array[() -> Unit] = []
  for slot in self.snapshots {
    restore.push((slot.snapshot)())
  }
  self.marks.push({
    name,
    seq: self.work_seq,
    restore,
    slots: self.snapshots.length(),
  })
}

///|
/// Drop the marks opened at or after the one named `name`, and everything the writes
/// queued after it would have left behind: the queues lose those writes, and each
/// identity map goes back to the copy the savepoint took. The mark itself stays — a
/// rollback to a savepoint keeps it open, as `ROLLBACK TO SAVEPOINT` does — so a
/// second rollback to the same savepoint is still a rollback to it.
///
/// Returns `false` when the session never opened a savepoint by that name, and the
/// caller is then rolling back something another session or a raw statement opened:
/// there is no session state to undo, so nothing is touched.
fn Core::rewind_to(self : Core, name : String) -> Bool {
  let mut found : Int32? = None
  for i = self.marks.length() - 1; i >= 0; i = i - 1 {
    if self.marks[i].name == name {
      found = Some(i)
      break
    }
  }
  let at = match found {
    Some(i) => i
    None => return false
  }
  let mark = self.marks[at]
  // A savepoint nested inside this one is gone once we roll back past it.
  while self.marks.length() > at + 1 {
    self.marks.pop() |> ignore
  }
  self.pending.retain(w => w.seq <= mark.seq)
  self.dirty.retain(w => w.seq <= mark.seq)
  self.deleted.retain(w => w.seq <= mark.seq)
  for undo in mark.restore {
    undo()
  }
  // A model this session first touched inside the savepoint holds nothing the rollback
  // left behind, so its slot goes.
  for i = mark.slots; i < self.snapshots.length(); i = i + 1 {
    (self.snapshots[i].drop)()
  }
  true
}

///|
/// Forget the mark named `name`, which a release does: the work merges into the
/// enclosing transaction, and the enclosing savepoint's own copy is what a rollback
/// there restores.
fn Core::close_mark(self : Core, name : String) -> Unit {
  let mut at : Int32? = None
  for i = self.marks.length() - 1; i >= 0; i = i - 1 {
    if self.marks[i].name == name {
      at = Some(i)
      break
    }
  }
  match at {
    Some(i) => self.marks.remove(i) |> ignore
    None => ()
  }
}

///|
/// Forget every savepoint, which a full rollback does: nothing can be rolled back to
/// once the enclosing transaction is gone.
fn Core::clear_marks(self : Core) -> Unit {
  self.marks.clear()
}

///|
/// Abandon everything queued and forget every record loaded.
fn Core::discard(self : Core) -> Unit {
  self.pending.clear()
  self.dirty.clear()
  self.deleted.clear()
  self.clear_marks()
  self.expunge_all()
}

///|
/// Forget the statements that executed, keeping whatever a failed flush never
/// reached.
fn Core::sweep(self : Core) -> Unit {
  self.pending.retain(w => !w.done)
  self.dirty.retain(w => !w.done)
  self.deleted.retain(w => !w.done)
}

///|
/// Run every listener registered for `ctx`'s event, in registration order.
fn Core::fire(self : Core, ctx : HookContext) -> Unit raise @moondb.DbError {
  for hook in self.hooks {
    if hook.0 == ctx.event {
      (hook.1)(ctx)
    }
  }
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
/// This session's slot in `model`'s identity map, created on first use and
/// registered for teardown so `expunge_all` can drop it again. Creating the slot also
/// registers how to copy it, which is what a savepoint snapshots.
fn[T] Core::slot(self : Core, model : @schema.Model[T]) -> Map[String, T] {
  match model.ident.get(self.id) {
    Some(m) => m
    None => {
      let m : Map[String, T] = Map([])
      model.ident.set(self.id, m)
      self.detach.push(() => model.ident.remove(self.id))
      // The handle can be replaced when a savepoint is rolled back, so the copy is
      // taken from whatever the model holds at savepoint time, not from `m`.
      self.snapshots.push({
        snapshot: () => {
          let copy = model.ident.get(self.id).unwrap_or(Map([])).copy()
          () => model.ident.set(self.id, copy)
        },
        drop: () => model.ident.remove(self.id),
      })
      m
    }
  }
}

///|
/// Put `record` in the identity map under its primary key. A record whose key the
/// model's projection does not carry — an autoincrement id the server assigns — stays
/// unidentified, so a later `get` reads it back from the database instead of handing
/// out a half-known instance.
fn[T] Core::remember(self : Core, model : @schema.Model[T], record : T) -> Unit {
  let key = model.pk_of(record)
  if key.length() > 0 && key.length() == model.pk_columns().length() {
    self.slot(model).set(identity_key(key), record)
  }
}

///|
/// The record this session already holds for `key`, or `None`.
fn[T] Core::lookup(
  self : Core,
  model : @schema.Model[T],
  key : Array[@moondb.Value],
) -> T? {
  self.slot(model).get(identity_key(key))
}

///|
/// Decode the row a by-key read returned and keep it under `key`, or `None` when the
/// read found nothing.
fn[T] Core::adopt(
  self : Core,
  model : @schema.Model[T],
  key : Array[@moondb.Value],
  rows : Array[@moondb.Row],
) -> T? raise @moondb.DbError {
  if rows.length() == 0 {
    return None
  }
  let record = model.map_row(rows[0])
  self.slot(model).set(identity_key(key), record)
  Some(record)
}

///|
/// Queue `record` for insertion, tagged with the queue serial a savepoint compares
/// against.
fn[T] Core::enqueue_insert(
  self : Core,
  dialect : @query.Dialect,
  model : @schema.Model[T],
  record : T,
) -> Unit {
  self.pending.push({
    table: model.table,
    parents: model.parent_tables(),
    seq: self.next_seq(),
    columns: () => (model.to_columns)(record),
    emit: columns => insert_statements(model.split_columns(columns), dialect),
    settle: () => self.remember(model, record),
    done: false,
  })
}

///|
/// Queue `record`'s current state as an `UPDATE` keyed on its primary key.
fn[T] Core::enqueue_update(
  self : Core,
  dialect : @query.Dialect,
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
  self.dirty.push({
    table: model.table,
    parents: model.parent_tables(),
    seq: self.next_seq(),
    columns: () => (model.to_columns)(record),
    emit: columns => update_statements(model, columns, dialect),
    settle: () => self.remember(model, record),
    done: false,
  })
}

///|
/// Queue `record` for deletion, done in the reverse dependency order at flush.
fn[T] Core::enqueue_delete(
  self : Core,
  dialect : @query.Dialect,
  model : @schema.Model[T],
  record : T,
) -> Unit raise @moondb.DbError {
  let key = record_key(model, record)
  let identity = identity_key(key)
  self.deleted.push({
    table: model.table,
    parents: model.parent_tables(),
    seq: self.next_seq(),
    columns: () => (model.to_columns)(record),
    emit: columns => delete_statements(model, columns, dialect),
    settle: () => self.slot(model).remove(identity),
    done: false,
  })
}

///|
/// Drop every record this session loaded, leaving the models themselves alone.
fn Core::expunge_all(self : Core) -> Unit {
  for drop in self.detach {
    drop()
  }
  self.detach.clear()
}

///|
/// Drop `record` from the identity map, so the next `get` reads the row back from the
/// database and returns a fresh instance.
fn[T] Core::forget(self : Core, model : @schema.Model[T], record : T) -> Unit {
  let key = model.pk_of(record)
  if key.length() > 0 && key.length() == model.pk_columns().length() {
    self.slot(model).remove(identity_key(key))
  }
}

///|
/// Normalise a key value for in-memory matching so a bound key equals the column
/// value a backend hands back, even across integer widths. A source key is built as
/// `Int(1)`, but SQLite (and others) return that column as `Int64(1)`, and the two
/// are distinct `Value` variants — a naive `==` would miss. Single-row `load` sidesteps
/// this because the match runs in SQL; a batch load matches in memory and must
/// reconcile the widths. Integers collapse to `Int64` and booleans to their `0`/`1`
/// integer (how SQL backends store them); other kinds compare as-is.
fn canonical_key(v : @moondb.Value) -> @moondb.Value {
  match v {
    @moondb.Int(n) => @moondb.Int64(n.to_int64())
    @moondb.Bool(b) => @moondb.Int64(if b { 1L } else { 0L })
    other => other
  }
}
