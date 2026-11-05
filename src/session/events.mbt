// Event hooks: the points where a caller can observe or adjust what the unit of work
// is about to do. SQLAlchemy dispatches these through `event.listen(...)` on a
// mapper or a session, with a different signature per event. MoonBit has one closure
// shape, so there is one context and every event hands it the same thing — the table,
// the row being written, and, for an `After*` hook, the statement that ran.

///|
/// The point in the unit of work a listener fires at. The `Before*` write hooks see
/// the row before it is rendered and may rewrite its columns; the `After*` hooks see
/// the statement that ran. `BeforeFlush` / `AfterFlush` bracket the whole flush, and
/// `BeforeCommit` / `AfterCommit` / `AfterRollback` bracket the transaction.
///
/// The names follow SQLAlchemy's `before_insert`, `after_insert` and friends, which
/// is why they are read as the phase they fire in rather than as statements.
#derive(Eq)
pub(all) enum HookEvent {
  BeforeInsert
  AfterInsert
  BeforeUpdate
  AfterUpdate
  BeforeDelete
  AfterDelete
  BeforeFlush
  AfterFlush
  BeforeCommit
  AfterCommit
  AfterRollback
}

///|
/// What a listener is told. `columns` is the row the unit of work is about to write,
/// as the model's `to_columns` projected it — and it is mutable, so a `Before*` hook
/// can stamp a timestamp, normalise a value, or drop a column, and the flush renders
/// what the hook left behind. For a delete it holds the primary key that addresses the
/// row. `sql` and `params` carry the statement that ran, filled in for `After*` hooks
/// and empty before it.
pub struct HookContext {
  event : HookEvent
  table : String
  mut columns : Array[(String, @moondb.Value)]
  mut sql : String
  mut params : Array[@moondb.Value]
}

///|
/// The context handed to one listener. Hooks outside a row-level statement — a flush
/// or a transaction boundary — carry no table and no columns.
pub fn HookContext::new(
  event : HookEvent,
  table~ : String = "",
  columns~ : Array[(String, @moondb.Value)] = [],
) -> HookContext {
  { event, table, columns, sql: "", params: [], }
}

///|
/// Replace a column's value in the row being written, or append it when the row does
/// not carry the column yet. This is how a `BeforeInsert` hook fills a column in —
/// SQLAlchemy's idiom of setting an attribute on the instance in `before_insert`.
pub fn HookContext::set_column(
  self : HookContext,
  name : String,
  value : @moondb.Value,
) -> Unit {
  for i in 0..<self.columns.length() {
    if self.columns[i].0 == name {
      self.columns[i] = (name, value)
      return
    }
  }
  self.columns.push((name, value))
}

///|
/// Replace the whole row being written. A hook that wants to drop or reorder columns
/// assigns a new array; `set_column` is the common case and edits in place.
pub fn HookContext::set_columns(
  self : HookContext,
  columns : Array[(String, @moondb.Value)],
) -> Unit {
  self.columns = columns
}

///|
/// The value the row carries for `name`, or `None`.
pub fn HookContext::column(self : HookContext, name : String) -> @moondb.Value? {
  for pair in self.columns {
    if pair.0 == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// Register a listener for `event` on this session. The listener runs for every
/// statement of that kind this session emits; narrowing it to one table is a check on
/// `ctx.table`, which is what a mapper-level listener in SQLAlchemy does by being
/// registered on that mapper.
///
/// Listeners run in registration order. A `Before*` listener that raises aborts the
/// flush before the statement is sent; nothing already executed is replayed, so a
/// rollback leaves the session where a failed flush would.
pub fn Session::on(
  self : Session,
  event : HookEvent,
  handler : (HookContext) -> Unit raise @moondb.DbError,
) -> Unit {
  self.hooks.push((event, handler))
}

///|
/// How many listeners are registered for `event`.
pub fn Session::listener_count(self : Session, event : HookEvent) -> Int32 {
  let mut n = 0
  for hook in self.hooks {
    if hook.0 == event {
      n = n + 1
    }
  }
  n
}

///|
/// Run every listener registered for `event`, in registration order.
fn Session::fire(
  self : Session,
  ctx : HookContext,
) -> Unit raise @moondb.DbError {
  for hook in self.hooks {
    if hook.0 == ctx.event {
      (hook.1)(ctx)
    }
  }
}

///|
/// Remove every listener, so a session can be reused with a fresh set of hooks.
pub fn Session::off_all(self : Session) -> Unit {
  self.hooks.clear()
}

///|
pub extend HookEvent with Eq::{not_equal, equal}
