// The execution layer: an explicit `Session` that runs the query builder's
// statements against any `@moondb.Driver` and hands back typed rows. moonorm owns
// no driver contract of its own — the seam is `@moondb`, so a `Session` drives a
// SQLite backend (moonsqlite), a Postgres backend, or the dependency-free
// `@moondb.MockDriver` interchangeably. Values still travel as bound parameters end
// to end, so the injection-safety guarantee reaches all the way to the wire.

///|
/// An explicit unit-of-work over a `@moondb.Driver`. Unlike SQLAlchemy's implicit
/// autoflush and attribute-triggered SQL, every statement here is issued explicitly
/// — the faithful MoonBit equivalent given the absence of attribute interception,
/// exactly as Diesel and GORM also require. It holds the backend as a
/// `&@moondb.Driver` trait object, so one `Session` type drives every backend.
///
/// The state — queues, identity map, savepoints — is `Core`'s; this type adds the one
/// thing a synchronous backend needs, a blocking call per rendered statement. Its
/// asynchronous twin [`AsyncSession`] wraps the same state around an
/// `@moondb.AsyncDriver`, so a program can move between the two without relearning
/// the API.
pub struct Session {
  driver : &@moondb.Driver
  dialect : @query.Dialect
  core : Core
}

///|
/// Wrap a connected driver in a session. `dialect` is what the session renders its statements
/// for, since a driver only takes SQL; it says SQLite unless told otherwise.
pub fn Session::new(
  driver : &@moondb.Driver,
  dialect~ : @query.Dialect = Sqlite,
) -> Session {
  { driver, dialect, core: Core::new(), }
}

///|
/// The dialect this session renders its statements for.
pub fn Session::dialect(self : Session) -> @query.Dialect {
  self.dialect
}

///|
/// How many nested savepoints opened via `begin_nested` are currently active.
pub fn Session::savepoint_depth(self : Session) -> Int32 {
  self.core.marks.length()
}

///|
/// Execute a raw statement with bound `params`.
pub fn Session::execute(
  self : Session,
  sql : String,
  params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  self.driver.execute(sql, params)
}

///|
/// Run a raw query with bound `params` and return its rows.
pub fn Session::query(
  self : Session,
  sql : String,
  params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.driver.query(sql, params)
}

///|
/// Build and run an `Insert` **now**, returning the affected-row count and new
/// rowid. This is the statement-level form: it goes to the driver on this call and
/// never touches the unit of work. To queue a record instead and let `flush` order
/// and emit it, use `add_record`.
///
/// Rendered for the session's dialect, which is what decides between `ON CONFLICT` and
/// `ON DUPLICATE KEY UPDATE`.
pub fn Session::add(
  self : Session,
  stmt : @query.Insert,
) -> @moondb.ExecResult raise @moondb.DbError {
  let (sql, params) = stmt.build_for(self.dialect)
  self.driver.execute(sql, params)
}

///|
/// Build and run a `Select`, returning the matched rows.
pub fn Session::fetch(
  self : Session,
  stmt : @query.Select,
) -> Array[@moondb.Row] raise @moondb.DbError {
  let (sql, params) = stmt.build()
  self.driver.query(sql, params)
}

///|
/// Build and run a `Select` and return the first column of its first row, or `None`
/// when it matched nothing — SQLAlchemy's `Session.scalar`, and the shape a `COUNT`,
/// an aggregate or a `RETURNING`-style probe comes back in.
pub fn Session::scalar(
  self : Session,
  stmt : @query.Select,
) -> @moondb.Value? raise @moondb.DbError {
  let rows = self.fetch(stmt)
  if rows.length() == 0 {
    return None
  }
  Some(rows[0].get(0))
}

///|
/// Build and run a `Select` and return the first column of every row — SQLAlchemy's
/// `Session.scalars`. Decoding into a record is `fetch_as`; this is for the queries
/// whose answer is a single column.
pub fn Session::scalars(
  self : Session,
  stmt : @query.Select,
) -> Array[@moondb.Value] raise @moondb.DbError {
  let out : Array[@moondb.Value] = []
  for row in self.fetch(stmt) {
    out.push(row.get(0))
  }
  out
}

///|
/// Stream a raw query's rows through a [`@moondb.Cursor`] instead of materialising
/// them — the bounded-memory counterpart to [`query`] (SQLAlchemy's
/// `stream_results`). This seam is synchronous, so only a synchronous driver with
/// incremental fetch streams lazily here: moonsqlite steps its prepared statement
/// row by row. A wire driver's cursor is async and cannot come through here at all
/// — moonpostgres implements `@moondb.AsyncDriver` instead, so it never sits
/// behind a `Session`; MySQL's synchronous adapter falls back to a materialised
/// cursor. For lazy streaming over the wire call [`AsyncSession::query_stream`]
/// under an event loop.
pub fn Session::query_stream(
  self : Session,
  sql : String,
  params : Array[@moondb.Value],
) -> &@moondb.Cursor raise @moondb.DbError {
  self.driver.query_stream(sql, params)
}

///|
/// Build and stream a `Select`, yielding raw rows through a cursor.
pub fn Session::stream(
  self : Session,
  stmt : @query.Select,
) -> &@moondb.Cursor raise @moondb.DbError {
  let (sql, params) = stmt.build()
  self.driver.query_stream(sql, params)
}

///|
/// Build and stream a `Select`, decoding each row into a `T` on demand — the
/// streaming counterpart to [`fetch_as`].
pub fn[T] Session::stream_as(
  self : Session,
  model : @schema.Model[T],
  stmt : @query.Select,
) -> RowStream[T] raise @moondb.DbError {
  let (sql, params) = stmt.build()
  { cursor: self.driver.query_stream(sql, params), model, }
}

///|
/// Build and run an `Update`, returning the affected-row count.
pub fn Session::modify(
  self : Session,
  stmt : @query.Update,
) -> @moondb.ExecResult raise @moondb.DbError {
  let (sql, params) = stmt.build_for(self.dialect)
  self.driver.execute(sql, params)
}

///|
/// Build and run a `Delete`, returning the affected-row count.
pub fn Session::remove(
  self : Session,
  stmt : @query.Delete,
) -> @moondb.ExecResult raise @moondb.DbError {
  let (sql, params) = stmt.build_for(self.dialect)
  self.driver.execute(sql, params)
}

///|
/// A lost update was detected: an optimistic-lock `UPDATE` matched no row because
/// the row's version had already moved on since it was read. Raised by
/// `Session::modify_versioned`.
pub(all) suberror LostUpdate {
  LostUpdate(String)
}

///|
/// Prints the row and the version that was expected, which is what a caller needs
/// to decide whether to reload and retry.
pub impl Show for LostUpdate with fn output(self : LostUpdate, logger : &Logger) -> Unit {
  let LostUpdate(m) = self
  logger.write_string("LostUpdate: " + m)
}

///|
/// Run a versioned `UPDATE` under optimistic concurrency control. `stmt` must carry
/// the version predicate in its `WHERE` (e.g. `where_(version_col, "=",
/// expected)`) and bump the version column in its `SET`. If the update matches no
/// row the version has moved on since it was read — a lost update — and this raises
/// `LostUpdate` instead of silently doing nothing, the faithful equivalent of
/// SQLAlchemy's `version_id_col` StaleDataError. The whole statement is
/// parameterised, so both the version guard and the new values stay bound.
pub fn Session::modify_versioned(
  self : Session,
  stmt : @query.Update,
  what~ : String = "row",
) -> @moondb.ExecResult raise {
  let (sql, params) = stmt.build()
  let res = self.driver.execute(sql, params)
  if res.rows_affected == 0L {
    raise LostUpdate(
      what + " was modified concurrently: no row matched the expected version",
    )
  }
  res
}

///|
/// Begin an explicit transaction. Delegates to the driver's transaction bracket
/// (`@moondb.Driver::begin`) rather than emitting `BEGIN` as text, so a driver that
/// manages transactions out-of-band (or maps them to savepoints) stays in control.
pub fn Session::begin(self : Session) -> Unit raise @moondb.DbError {
  self.driver.begin()
}

///|
/// Run the statements that put a connection back the way it was before this session's
/// transaction changed connection-level state. SQLite's `PRAGMA query_only` is set on
/// the connection, not the transaction, so a read-only transaction that ends without
/// clearing it would leave a pooled connection that cannot write — the failure shows
/// up one borrower later, in a transaction that asked for nothing.
fn Session::end_transaction(self : Session) -> Unit raise @moondb.DbError {
  let restore = self.core.restore
  self.core.restore = []
  for statement in restore {
    self.driver.execute(statement, []) |> ignore
  }
}

///|
/// Flush the unit of work, then commit the current transaction. Queued records reach
/// the database here if nothing has flushed them yet, which is why a caller can add
/// and commit without naming `flush` at all. With an empty queue this is the bare
/// driver commit.
///
/// `BeforeCommit` runs before the flush, so a listener sees the queue it is about to
/// write; `AfterCommit` runs once the driver has committed. Any connection-level
/// transaction option is put back before `AfterCommit`, so a listener already sees the
/// connection as the next borrower will.
pub fn Session::commit(self : Session) -> Unit raise @moondb.DbError {
  self.core.fire(HookContext::new(BeforeCommit))
  self.flush()
  self.driver.commit()
  self.end_transaction()
  self.core.fire(HookContext::new(AfterCommit))
}

///|
/// Run `body` inside one transaction: begin, run, commit; on failure roll back and
/// re-raise what `body` raised, so the caller sees the real cause rather than the
/// rollback's outcome.
///
/// The driver's own `begin`/`commit`/`rollback` are used — not SQL text — so a driver
/// that manages the transaction out of band stays in control. Nothing queued in the
/// unit of work is flushed here: this brackets statements the caller issues.
pub fn Session::transaction(
  self : Session,
  body : () -> Unit raise @moondb.DbError,
) -> Unit raise @moondb.DbError {
  self.driver.begin()
  let outcome = try {
    body()
    Ok(())
  } catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => {
      self.driver.commit()
      self.end_transaction()
    }
    Err(e) => {
      // A rollback that fails leaves the transaction state unknown, but the error
      // worth reporting is the one that aborted the body.
      let undone = try {
        self.driver.rollback()
        Ok(())
      } catch {
        _ => Err(())
      }
      ignore(undone)
      raise e
    }
  }
}

///|
/// Roll back the current transaction, abandoning whatever is still queued and
/// emptying the identity map. The records held there describe rows the rollback has
/// just undone, so keeping them would hand out state the database no longer has.
/// `AfterRollback` runs once the driver has rolled back and any connection-level
/// transaction option has been put back.
pub fn Session::rollback(self : Session) -> Unit raise @moondb.DbError {
  self.core.discard()
  self.driver.rollback()
  self.end_transaction()
  self.core.fire(HookContext::new(AfterRollback))
}

///|
/// Open a nested transaction with `SAVEPOINT <name>`. Savepoints nest arbitrarily,
/// so this is the faithful equivalent of SQLAlchemy's `Session.begin_nested()`:
/// work done after the savepoint can be undone with `rollback_to(name)` without
/// discarding the enclosing transaction, and finalised with `release(name)`.
///
/// `name` must be a bare identifier (it is interpolated as an identifier, never a
/// bound value); a non-identifier raises `QueryError` rather than reaching the
/// database. The statement is issued through `execute`, so a backend that supports
/// SQL savepoints (SQLite, Postgres) runs it verbatim.
pub fn Session::savepoint(
  self : Session,
  name : String,
) -> @moondb.ExecResult raise @moondb.DbError {
  if !@query.is_ident(name) {
    raise @moondb.QueryError("invalid savepoint name: " + name)
  }
  let res = self.driver.execute("SAVEPOINT " + name, [])
  self.core.open_mark(name)
  res
}

///|
/// Roll back to a savepoint (`ROLLBACK TO SAVEPOINT <name>`), undoing everything
/// done since it was opened while keeping the savepoint (and the outer transaction)
/// active. Rejects a non-identifier `name` with `QueryError`.
///
/// The database is only half of it: the session's queues and identity map are put back
/// as well, so a record inserted inside the savepoint stops being reachable and an
/// updated one goes back to the values the database rolled back to. Anything else
/// would hand a caller rows that no longer exist, or replay a write the rollback
/// undid at the next flush.
pub fn Session::rollback_to(
  self : Session,
  name : String,
) -> @moondb.ExecResult raise @moondb.DbError {
  if !@query.is_ident(name) {
    raise @moondb.QueryError("invalid savepoint name: " + name)
  }
  let res = self.driver.execute("ROLLBACK TO SAVEPOINT " + name, [])
  self.core.rewind_to(name) |> ignore
  res
}

///|
/// Release a savepoint (`RELEASE SAVEPOINT <name>`), merging its work into the
/// enclosing transaction (or savepoint). Rejects a non-identifier `name`.
pub fn Session::release(
  self : Session,
  name : String,
) -> @moondb.ExecResult raise @moondb.DbError {
  if !@query.is_ident(name) {
    raise @moondb.QueryError("invalid savepoint name: " + name)
  }
  let res = self.driver.execute("RELEASE SAVEPOINT " + name, [])
  self.core.close_mark(name)
  res
}

///|
/// Open a nested transaction — `SAVEPOINT <auto-name>` — and return a handle that
/// tracks its name and depth, so callers never spell (or risk mis-spelling) a
/// savepoint name. Nesting `begin_nested` inside another increases the depth; each
/// handle's `release`/`rollback` brings it back down. This is the ergonomic,
/// depth-tracked counterpart of the raw `savepoint`/`rollback_to`/`release` trio,
/// mirroring SQLAlchemy's `begin_nested()`.
///
/// The generated name (`moonorm_sp_<n>`, `n` strictly increasing per session) is a
/// bare identifier by construction, so it is injection-safe without a runtime check.
pub fn Session::begin_nested(self : Session) -> Savepoint raise @moondb.DbError {
  self.core.sp_seq = self.core.sp_seq + 1
  let name = "moonorm_sp_" + self.core.sp_seq.to_string()
  self.driver.execute("SAVEPOINT " + name, []) |> ignore
  self.core.open_mark(name)
  { sess: self, name, depth: self.core.marks.length(), finished: false, }
}

///|
/// Whether `dialect` wants the transaction-characteristics statements issued
/// *before* `BEGIN` rather than after. MySQL's scopeless `SET TRANSACTION` configures
/// the next transaction and must precede it; PostgreSQL's `SET TRANSACTION` runs
/// inside the transaction, after `BEGIN`. SQLite's `PRAGMA`s are connection-level, so
/// issuing them first is fine.
fn tx_opts_before_begin(dialect : @query.Dialect) -> Bool {
  match dialect {
    Postgres => false
    _ => true
  }
}

///|
/// Begin a transaction with explicit isolation / read-only options. It brackets the
/// driver's `begin` with the `SET TRANSACTION` (or `PRAGMA`) statements `opts`
/// renders for the session's dialect, ordered so each backend accepts them: before `BEGIN` for
/// MySQL and SQLite, after `BEGIN` for PostgreSQL (see `TxOptions::to_sql`). Commit or roll back
/// with the usual `commit`/`rollback`.
///
/// A connection-level option is not undone by the database when the transaction ends,
/// so `commit` and `rollback` put it back (see `TxOptions::restore_sql`).
pub fn Session::begin_with(
  self : Session,
  opts : TxOptions,
) -> Unit raise @moondb.DbError {
  let stmts = opts.to_sql(self.dialect)
  // Remember what to undo before any of it is sent: a `begin` that then fails still
  // leaves the option set on the connection.
  self.core.restore = opts.restore_sql(self.dialect)
  if tx_opts_before_begin(self.dialect) {
    for s in stmts {
      self.driver.execute(s, []) |> ignore
    }
    self.driver.begin()
  } else {
    self.driver.begin()
    for s in stmts {
      self.driver.execute(s, []) |> ignore
    }
  }
}

///|
/// Create the table backing `model` from its declared columns, then its
/// indexes (see `Model::create_table_sql` and `Model::create_indexes_sql`).
/// With `if_not_exists=true` the DDL is idempotent.
pub fn[T] Session::create_table(
  self : Session,
  model : @schema.Model[T],
  if_not_exists~ : Bool = false,
) -> @moondb.ExecResult raise @moondb.DbError {
  let made = self.driver.execute(
    model.create_table_sql_for(self.dialect, if_not_exists~),
    [],
  )
  for statement in model.create_indexes_sql_for(self.dialect, if_not_exists~) {
    self.driver.execute(statement, []) |> ignore
  }
  made
}

///|
/// Insert a mapped `record` through its `model` **now**, binding the model's
/// `to_columns` pairs. Returns the affected-row count and new rowid. Nothing is
/// queued and the identity map is not consulted; `add_record` is the unit-of-work
/// counterpart that defers to `flush`.
///
/// A joined-table subclass is written as two statements here as well — the parent row
/// first — because the subclass row's foreign key needs it. The `Before*`/`After*`
/// insert hooks fire around the write exactly as they do at flush.
pub fn[T] Session::insert_record(
  self : Session,
  model : @schema.Model[T],
  record : T,
) -> @moondb.ExecResult raise @moondb.DbError {
  let columns = (model.to_columns)(record)
  let ctx = HookContext::new(BeforeInsert, table=model.table, columns~)
  self.core.fire(ctx)
  let statements = insert_statements(
    model.split_columns(ctx.columns),
    self.dialect,
  )
  let mut result : @moondb.ExecResult = {
    rows_affected: 0L,
    last_insert_id: 0L,
  }
  let mut last_sql = ""
  let mut last_params : Array[@moondb.Value] = []
  for statement in statements {
    let (sql, params) = statement
    result = self.driver.execute(sql, params)
    last_sql = sql
    last_params = params
  }
  let done = HookContext::new(
    AfterInsert,
    table=model.table,
    columns=ctx.columns,
  )
  done.sql = last_sql
  done.params = last_params
  self.core.fire(done)
  result
}

///|
/// Run a `Select` and decode every row into a `T` via `model`. Use it with a
/// `Model::select()` (optionally refined with `where_`/`order_by`) to get records
/// rather than raw `Row`s back.
pub fn[T] Session::fetch_as(
  self : Session,
  model : @schema.Model[T],
  stmt : @query.Select,
) -> Array[T] raise @moondb.DbError {
  let (sql, params) = stmt.build()
  model.map_rows(self.driver.query(sql, params))
}

///|
/// Fetch every row of a model's table, decoded into records (`SELECT <cols> FROM
/// <table>`).
pub fn[T] Session::all(
  self : Session,
  model : @schema.Model[T],
) -> Array[T] raise @moondb.DbError {
  self.fetch_as(model, model.select())
}

///|
/// Eagerly load the related records of a 1:N relationship: given a `source` parent,
/// run the relationship's query and decode every matching child into a record. This
/// is the explicit stand-in for SQLAlchemy's transparent lazy load (`parent.children`
/// firing a SELECT on attribute access) — MoonBit has no attribute interception, so
/// the load is a call, exactly as Diesel and GORM require. The match value is bound,
/// so eager loading stays injection-safe.
pub fn[S, T] Session::load(
  self : Session,
  source : S,
  rel : @schema.Relation[S, T],
  strategy~ : @schema.LoadStrategy = @schema.SubqueryLoad,
) -> Array[T] raise @moondb.DbError {
  let (sql, params) = relation_sql(rel, source, strategy~)
  rel.target.map_rows(self.driver.query(sql, params))
}

///|
/// Eagerly load the single related record of a N:1 relationship (e.g. a child's
/// parent): the first matching row decoded into a record, or `None` if there is no
/// match. Like `load`, the match value is bound.
pub fn[S, T] Session::load_one(
  self : Session,
  source : S,
  rel : @schema.Relation[S, T],
  strategy~ : @schema.LoadStrategy = @schema.SubqueryLoad,
) -> T? raise @moondb.DbError {
  let (sql, params) = relation_one_sql(rel, source, strategy~)
  let rows = self.driver.query(sql, params)
  if rows.length() == 0 {
    None
  } else {
    Some(rel.target.map_row(rows[0]))
  }
}

///|
/// The statement one 1:N load runs: the relationship's own query, or the JOIN form
/// when the strategy asks for one. A `RaiseLoad` relation refuses instead of quietly
/// issuing the query it was told not to.
fn[S, T] relation_sql(
  rel : @schema.Relation[S, T],
  source : S,
  strategy~ : @schema.LoadStrategy,
) -> (String, Array[@moondb.Value]) raise @moondb.DbError {
  match strategy {
    @schema.RaiseLoad =>
      raise @moondb.QueryError(
        "raiseload: the relation was not loaded explicitly",
      )
    @schema.SubqueryLoad => rel.query(source).build()
    @schema.JoinedLoad => rel.joined_sql([source])
  }
}

///|
/// The statement one N:1 load runs, capped at one row.
fn[S, T] relation_one_sql(
  rel : @schema.Relation[S, T],
  source : S,
  strategy~ : @schema.LoadStrategy,
) -> (String, Array[@moondb.Value]) raise @moondb.DbError {
  match strategy {
    @schema.RaiseLoad =>
      raise @moondb.QueryError(
        "raiseload: the relation was not loaded explicitly",
      )
    @schema.SubqueryLoad => rel.query(source).limit(1).build()
    @schema.JoinedLoad => {
      let (sql, params) = rel.joined_sql([source])
      (sql + " LIMIT 1", params)
    }
  }
}

///|
/// Eagerly load a 1:N relationship for *many* sources in a single query, avoiding
/// the N+1 problem. Naively calling `load` in a loop fires one SELECT per source;
/// this instead issues one `SELECT … WHERE key_column IN (all the source keys)`,
/// then buckets the fetched children back to their parents in memory. The return is
/// index-aligned with `sources`: `result[i]` is the list of children whose foreign
/// key matches `sources[i]`'s key (empty if none). This is the explicit equivalent
/// of SQLAlchemy's `selectinload` eager strategy.
///
/// Children are matched to a source by comparing the child row's `key_column` value
/// against the source's extracted key, so a source with no children yields an empty
/// list and children are shared correctly when two sources happen to hold the same
/// key. An empty `sources` returns an empty array without touching the database.
pub fn[S, T] Session::load_batch(
  self : Session,
  sources : Array[S],
  rel : @schema.Relation[S, T],
  strategy~ : @schema.LoadStrategy = @schema.SubqueryLoad,
) -> Array[Array[T]] raise @moondb.DbError {
  let result : Array[Array[T]] = []
  for _ in sources {
    result.push([])
  }
  if sources.length() == 0 {
    return result
  }
  let (sql, params) = relation_batch_sql(rel, sources, strategy~)
  let rows = self.driver.query(sql, params)
  bucket_children(result, rows, sources, rel)
  result
}

///|
/// The statement a batched 1:N load runs.
fn[S, T] relation_batch_sql(
  rel : @schema.Relation[S, T],
  sources : Array[S],
  strategy~ : @schema.LoadStrategy,
) -> (String, Array[@moondb.Value]) raise @moondb.DbError {
  match strategy {
    @schema.RaiseLoad =>
      raise @moondb.QueryError(
        "raiseload: the relation was not loaded explicitly",
      )
    @schema.SubqueryLoad => rel.batch_query(sources).build()
    @schema.JoinedLoad => rel.joined_sql(sources)
  }
}

///|
/// Bucket every fetched child to the sources it belongs to. The child's foreign key
/// lives in the row under `key_column`; a source claims the child when its extracted
/// key equals that value.
fn[S, T] bucket_children(
  result : Array[Array[T]],
  rows : Array[@moondb.Row],
  sources : Array[S],
  rel : @schema.Relation[S, T],
) -> Unit raise @moondb.DbError {
  for row in rows {
    let child_key = match row.by_name(rel.key_column) {
      Some(v) => v
      None =>
        raise @moondb.QueryError(
          "batch load: fetched row has no column " + rel.key_column,
        )
    }
    let record = rel.target.map_row(row)
    for i = 0; i < sources.length(); i = i + 1 {
      if canonical_key(rel.source_value(sources[i])) == canonical_key(child_key) {
        result[i].push(record)
      }
    }
  }
}

///|
/// Eagerly load a N:1 relationship for *many* sources in a single query — the
/// to-one counterpart of `load_batch`. One `SELECT … WHERE key_column IN (…)` fetches
/// every distinct parent; the return is index-aligned with `sources`, `result[i]`
/// being `sources[i]`'s parent (`Some`) or `None` when there is no match. Avoids the
/// N+1 that a per-source `load_one` loop would incur.
pub fn[S, T] Session::load_one_batch(
  self : Session,
  sources : Array[S],
  rel : @schema.Relation[S, T],
  strategy~ : @schema.LoadStrategy = @schema.SubqueryLoad,
) -> Array[T?] raise @moondb.DbError {
  let result : Array[T?] = []
  for _ in sources {
    result.push(None)
  }
  if sources.length() == 0 {
    return result
  }
  let (sql, params) = relation_batch_sql(rel, sources, strategy~)
  let rows = self.driver.query(sql, params)
  for row in rows {
    let parent_key = match row.by_name(rel.key_column) {
      Some(v) => v
      None =>
        raise @moondb.QueryError(
          "batch load: fetched row has no column " + rel.key_column,
        )
    }
    let record = rel.target.map_row(row)
    for i = 0; i < sources.length(); i = i + 1 {
      if result[i] is None &&
        canonical_key(rel.source_value(sources[i])) == canonical_key(parent_key) {
        result[i] = Some(record)
      }
    }
  }
  result
}

///|
/// Close the session's underlying connection, dropping anything still queued and
/// every record the identity map holds.
pub fn Session::close(self : Session) -> Unit {
  self.core.discard()
  self.driver.close()
}

///|
/// Eagerly load the related records of a many-to-many relationship: run the
/// junction JOIN for `source` and decode every matching target row. The N:M
/// counterpart of `Session::load`, and like it the source key is bound, so eager
/// loading stays injection-safe.
pub fn[S, T] Session::load_many(
  self : Session,
  source : S,
  rel : @schema.ManyToMany[S, T],
  strategy~ : @schema.LoadStrategy = @schema.SubqueryLoad,
) -> Array[T] raise @moondb.DbError {
  let (sql, params) = match strategy {
    @schema.RaiseLoad =>
      raise @moondb.QueryError(
        "raiseload: the relation was not loaded explicitly",
      )
    @schema.SubqueryLoad => rel.query(source).build()
    @schema.JoinedLoad => rel.joined_sql([source])
  }
  rel.target.map_rows(self.driver.query(sql, params))
}

///|
/// Eagerly load an N:M relationship for many sources in a single query, bucketing the
/// fetched targets to their sources in memory. The counterpart of `load_batch` for a
/// junction-table relation; `strategy` chooses an `IN` query or a JOIN. Returns an
/// array index-aligned with `sources`.
pub fn[S, T] Session::load_many_batch(
  self : Session,
  sources : Array[S],
  rel : @schema.ManyToMany[S, T],
  strategy~ : @schema.LoadStrategy = @schema.SubqueryLoad,
) -> Array[Array[T]] raise @moondb.DbError {
  let result : Array[Array[T]] = []
  for _ in sources {
    result.push([])
  }
  if sources.length() == 0 {
    return result
  }
  let (sql, params) = match strategy {
    @schema.RaiseLoad =>
      raise @moondb.QueryError(
        "raiseload: the relation was not loaded explicitly",
      )
    @schema.SubqueryLoad => rel.batch_sql(sources)
    @schema.JoinedLoad => rel.joined_sql(sources)
  }
  for row in self.driver.query(sql, params) {
    bucket_many(result, row, sources, rel)
  }
  result
}

///|
/// Bucket one junction row to every source whose key it carries. The junction's source
/// key rides along as `moonorm_src`.
fn[S, T] bucket_many(
  result : Array[Array[T]],
  row : @moondb.Row,
  sources : Array[S],
  rel : @schema.ManyToMany[S, T],
) -> Unit raise @moondb.DbError {
  let src = match row.by_name("moonorm_src") {
    Some(v) => v
    None =>
      raise @moondb.QueryError(
        "load_many_batch: fetched row has no moonorm_src",
      )
  }
  let record = rel.target.map_row(row)
  for i = 0; i < sources.length(); i = i + 1 {
    if canonical_key(rel.source_value(sources[i])) == canonical_key(src) {
      result[i].push(record)
    }
  }
}

///|
pub extend LostUpdate with Show::{to_string, output}
