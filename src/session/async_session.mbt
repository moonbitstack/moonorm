// The asynchronous execution layer: the same unit of work as `Session`, driving an
// `@moondb.AsyncDriver` instead of a blocking one. A wire backend — PostgreSQL over a
// socket, MySQL through moonbitlang/async — only implements `AsyncDriver`, so before
// this type existed the ORM could not reach one at all: a `Session` borrows a
// `&@moondb.Driver`, and there is no way to call an async method from a synchronous
// one without blocking the whole event loop.
//
// The two types are not two implementations. Everything that decides *what* happens —
// the queues, the dependency order, the identity map, the savepoint marks — is
// `Core`'s, and every method here is the same method with an `await` where the
// synchronous twin has a blocking call. A program that starts on SQLite and later
// points at a networked server changes the session type, not its logic.

///|
/// An explicit unit of work over an `@moondb.AsyncDriver` — [`Session`] with every
/// call awaited.
///
/// One session is one connection, so it runs one statement at a time; concurrency
/// comes from running several sessions at once, which is exactly what
/// [`with_pool`](AsyncSession::with_pool) is for. Nothing is shared between two
/// sessions except the models they were built from, and each keeps its own identity
/// map.
pub struct AsyncSession {
  driver : &@moondb.AsyncDriver
  dialect : @query.Dialect
  core : Core
}

///|
/// Wrap a connected async driver in a session. `dialect` is what the session renders
/// its statements for, since a driver only takes SQL; it says SQLite unless told
/// otherwise.
pub fn AsyncSession::new(
  driver : &@moondb.AsyncDriver,
  dialect~ : @query.Dialect = Sqlite,
) -> AsyncSession {
  { driver, dialect, core: Core::new(), }
}

///|
/// The dialect this session renders its statements for.
pub fn AsyncSession::dialect(self : AsyncSession) -> @query.Dialect {
  self.dialect
}

///|
/// How many nested savepoints opened via `begin_nested` are currently active.
pub fn AsyncSession::savepoint_depth(self : AsyncSession) -> Int32 {
  self.core.marks.length()
}

///|
/// Execute a raw statement with bound `params`.
pub async fn AsyncSession::execute(
  self : AsyncSession,
  sql : String,
  params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  self.driver.execute(sql, params)
}

///|
/// Run a raw query with bound `params` and return its rows.
pub async fn AsyncSession::query(
  self : AsyncSession,
  sql : String,
  params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.driver.query(sql, params)
}

///|
/// Build and run an `Insert` now, returning the affected-row count and new rowid. The
/// statement-level form: it never touches the unit of work.
pub async fn AsyncSession::add(
  self : AsyncSession,
  stmt : @query.Insert,
) -> @moondb.ExecResult raise @moondb.DbError {
  let (sql, params) = stmt.build_for(self.dialect)
  self.driver.execute(sql, params)
}

///|
/// Build and run a `Select`, returning the matched rows.
pub async fn AsyncSession::fetch(
  self : AsyncSession,
  stmt : @query.Select,
) -> Array[@moondb.Row] raise @moondb.DbError {
  let (sql, params) = stmt.build()
  self.driver.query(sql, params)
}

///|
/// Build and run a `Select` and return the first column of its first row, or `None`
/// when it matched nothing.
pub async fn AsyncSession::scalar(
  self : AsyncSession,
  stmt : @query.Select,
) -> @moondb.Value? raise @moondb.DbError {
  let rows = self.fetch(stmt)
  if rows.length() == 0 {
    return None
  }
  Some(rows[0].get(0))
}

///|
/// Build and run a `Select` and return the first column of every row.
pub async fn AsyncSession::scalars(
  self : AsyncSession,
  stmt : @query.Select,
) -> Array[@moondb.Value] raise @moondb.DbError {
  let out : Array[@moondb.Value] = []
  for row in self.fetch(stmt) {
    out.push(row.get(0))
  }
  out
}

///|
/// Stream a raw query's rows through an [`@moondb.AsyncCursor`], reading each row off
/// the wire when it is asked for — the bounded-memory counterpart to [`query`],
/// and the part a synchronous `Session` cannot offer a networked backend at all.
///
/// The cursor must be drained or closed: MoonBit has no finaliser, so an abandoned one
/// leaves the statement open and the connection mid-result.
pub async fn AsyncSession::query_stream(
  self : AsyncSession,
  sql : String,
  params : Array[@moondb.Value],
) -> &@moondb.AsyncCursor raise @moondb.DbError {
  self.driver.query_stream(sql, params)
}

///|
/// Build and stream a `Select`, yielding raw rows through a cursor.
pub async fn AsyncSession::stream(
  self : AsyncSession,
  stmt : @query.Select,
) -> &@moondb.AsyncCursor raise @moondb.DbError {
  let (sql, params) = stmt.build()
  self.driver.query_stream(sql, params)
}

///|
/// Build and stream a `Select`, decoding each row into a `T` on demand — the
/// streaming counterpart to [`fetch_as`](AsyncSession::fetch_as), and the
/// `yield_per` shape a large read wants.
pub async fn[T] AsyncSession::stream_as(
  self : AsyncSession,
  model : @schema.Model[T],
  stmt : @query.Select,
) -> AsyncRowStream[T] raise @moondb.DbError {
  let (sql, params) = stmt.build()
  { cursor: self.driver.query_stream(sql, params), model, }
}

///|
/// Build and run an `Update`, returning the affected-row count.
pub async fn AsyncSession::modify(
  self : AsyncSession,
  stmt : @query.Update,
) -> @moondb.ExecResult raise @moondb.DbError {
  let (sql, params) = stmt.build_for(self.dialect)
  self.driver.execute(sql, params)
}

///|
/// Build and run a `Delete`, returning the affected-row count.
pub async fn AsyncSession::remove(
  self : AsyncSession,
  stmt : @query.Delete,
) -> @moondb.ExecResult raise @moondb.DbError {
  let (sql, params) = stmt.build_for(self.dialect)
  self.driver.execute(sql, params)
}

///|
/// Run a versioned `UPDATE` under optimistic concurrency control, raising
/// [`LostUpdate`] when no row matched the expected version — see
/// [`Session::modify_versioned`].
pub async fn AsyncSession::modify_versioned(
  self : AsyncSession,
  stmt : @query.Update,
  what~ : String = "row",
) -> @moondb.ExecResult {
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
/// Begin an explicit transaction through the driver's own bracket, so a backend that
/// tracks transactions out of band stays in control.
pub async fn AsyncSession::begin(
  self : AsyncSession,
) -> Unit raise @moondb.DbError {
  self.driver.begin()
}

///|
/// Put back what a transaction changed at the connection level — see
/// [`Session::end_transaction`](Session#end_transaction). SQLite's `PRAGMA query_only`
/// lives on the connection, so it has to be cleared before the connection goes back to
/// a pool that may lend it to a writer.
async fn AsyncSession::end_transaction(
  self : AsyncSession,
) -> Unit raise @moondb.DbError {
  let restore = self.core.restore
  self.core.restore = []
  for statement in restore {
    self.driver.execute(statement, []) |> ignore
  }
}

///|
/// Flush the unit of work, then commit. `BeforeCommit` fires before the flush and
/// `AfterCommit` once the driver has committed and the connection is back to its
/// untransacted state.
pub async fn AsyncSession::commit(
  self : AsyncSession,
) -> Unit raise @moondb.DbError {
  self.core.fire(HookContext::new(BeforeCommit))
  self.flush()
  self.driver.commit()
  self.end_transaction()
  self.core.fire(HookContext::new(AfterCommit))
}

///|
/// Run `body` inside one transaction: begin, run, commit; on failure roll back and
/// re-raise what `body` raised. `body` is awaited, so the whole bracket is one task's.
pub async fn AsyncSession::transaction(
  self : AsyncSession,
  body : async () -> Unit raise @moondb.DbError,
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
/// Roll back the current transaction, abandoning whatever is queued and emptying the
/// identity map, then re-raise nothing: the caller keeps going as the synchronous twin
/// does.
pub async fn AsyncSession::rollback(
  self : AsyncSession,
) -> Unit raise @moondb.DbError {
  self.core.discard()
  self.driver.rollback()
  self.end_transaction()
  self.core.fire(HookContext::new(AfterRollback))
}

///|
/// Open a nested transaction with `SAVEPOINT <name>`. Rejects a non-identifier `name`
/// with `QueryError` before anything reaches the server.
pub async fn AsyncSession::savepoint(
  self : AsyncSession,
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
/// Roll back to a savepoint, undoing everything done since it opened in the database
/// *and* in the session: writes queued after it leave the queues, and the identity map
/// returns to the records it held when the savepoint opened.
pub async fn AsyncSession::rollback_to(
  self : AsyncSession,
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
/// Release a savepoint, merging its work into the enclosing transaction.
pub async fn AsyncSession::release(
  self : AsyncSession,
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
/// Open a nested transaction with an auto-generated name and return its handle — the
/// awaited counterpart of [`Session::begin_nested`], with the same depth tracking
/// and the same session-state rollback.
pub async fn AsyncSession::begin_nested(
  self : AsyncSession,
) -> AsyncSavepoint raise @moondb.DbError {
  self.core.sp_seq = self.core.sp_seq + 1
  let name = "moonorm_sp_" + self.core.sp_seq.to_string()
  self.driver.execute("SAVEPOINT " + name, []) |> ignore
  self.core.open_mark(name)
  { sess: self, name, depth: self.core.marks.length(), finished: false, }
}

///|
/// Begin a transaction with explicit isolation / read-only options, ordered for the
/// session's dialect exactly as [`Session::begin_with`] does. The statements that undo
/// a connection-level option run when `commit` or `rollback` ends the transaction.
pub async fn AsyncSession::begin_with(
  self : AsyncSession,
  opts : TxOptions,
) -> Unit raise @moondb.DbError {
  let stmts = opts.to_sql(self.dialect)
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
/// Create the table backing `model` from its declared columns, then its indexes.
pub async fn[T] AsyncSession::create_table(
  self : AsyncSession,
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
/// Insert a mapped `record` now, without queueing it — the awaited counterpart of
/// [`Session::insert_record`], including the joined-table split and the insert hooks.
pub async fn[T] AsyncSession::insert_record(
  self : AsyncSession,
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
/// Run a `Select` and decode every row into a `T` via `model`.
pub async fn[T] AsyncSession::fetch_as(
  self : AsyncSession,
  model : @schema.Model[T],
  stmt : @query.Select,
) -> Array[T] raise @moondb.DbError {
  let (sql, params) = stmt.build()
  model.map_rows(self.driver.query(sql, params))
}

///|
/// Fetch every row of a model's table, decoded into records.
pub async fn[T] AsyncSession::all(
  self : AsyncSession,
  model : @schema.Model[T],
) -> Array[T] raise @moondb.DbError {
  self.fetch_as(model, model.select())
}

///|
/// Eagerly load a 1:N relationship for one source — the awaited
/// [`Session::load`], with the same strategy choice and the same bound match
/// value.
pub async fn[S, T] AsyncSession::load(
  self : AsyncSession,
  source : S,
  rel : @schema.Relation[S, T],
  strategy~ : @schema.LoadStrategy = @schema.SubqueryLoad,
) -> Array[T] raise @moondb.DbError {
  let (sql, params) = relation_sql(rel, source, strategy~)
  rel.target.map_rows(self.driver.query(sql, params))
}

///|
/// Eagerly load the single related record of a N:1 relationship.
pub async fn[S, T] AsyncSession::load_one(
  self : AsyncSession,
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
/// Eagerly load a 1:N relationship for many sources in one query, index-aligned with
/// `sources` — the `selectinload` shape, without the N+1.
pub async fn[S, T] AsyncSession::load_batch(
  self : AsyncSession,
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
/// Eagerly load a N:1 relationship for many sources in one query.
pub async fn[S, T] AsyncSession::load_one_batch(
  self : AsyncSession,
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
/// Eagerly load the related records of an N:M relationship through its junction table.
pub async fn[S, T] AsyncSession::load_many(
  self : AsyncSession,
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
/// Eagerly load an N:M relationship for many sources in one query.
pub async fn[S, T] AsyncSession::load_many_batch(
  self : AsyncSession,
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
/// Close the session's connection, dropping everything queued and every record the
/// identity map holds.
pub async fn AsyncSession::close(self : AsyncSession) -> Unit noraise {
  self.core.discard()
  // A close that fails leaves a connection the next statement would refuse anyway, so
  // it is reported the way `@moondb.Cursor::close` reports it: nowhere.
  self.driver.close() catch {
    _ => ()
  }
}

///|
/// Run `f` with an `AsyncSession` on a connection borrowed from `pool`, returning it
/// when `f` finishes or raises — the awaited counterpart of
/// [`Session::with_pool`], and the entry that makes concurrency possible: two tasks
/// calling this at once take two connections and run at the same time.
///
/// The unit of work owns its transaction: commit or roll back inside `f` before it
/// returns, since the connection goes back to the pool as it was left.
pub async fn[D : @moondb.AsyncDriver, T] AsyncSession::with_pool(
  pool : @apool.AsyncPool[D],
  f : async (AsyncSession) -> T raise @moondb.DbError,
  dialect~ : @query.Dialect = Sqlite,
) -> T raise @moondb.DbError {
  pool.with_conn(conn => f(AsyncSession::new(conn, dialect~)))
}
