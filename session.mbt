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
pub struct Session {
  driver : &@moondb.Driver
  // Currently open nested savepoints, so `begin_nested` can auto-name and track
  // depth the way SQLAlchemy's `begin_nested()` does (the caller never spells a
  // savepoint name). `sp_seq` only ever increases, giving each savepoint a name
  // unique within the session even after earlier ones are released.
  mut sp_depth : Int
  mut sp_seq : Int
  // Names this session's slot in the identity map of every model it touches (see
  // `Model::ident`).
  id : Int
  pending : Array[Work]
  dirty : Array[Work]
  deleted : Array[Work]
  // Drops this session's identity slot out of each model it claimed one in. A model
  // is normally a long-lived top-level value, so nothing else would ever free it.
  detach : Array[() -> Unit]
}

///|
/// Session serials. Identity maps live in the models rather than the session, so a
/// session needs a name no other live session shares.
let session_seq : Ref[Int] = Ref(0)

///|
/// Wrap a connected driver in a session.
pub fn Session::new(driver : &@moondb.Driver) -> Session {
  session_seq.val = session_seq.val + 1
  {
    driver,
    sp_depth: 0,
    sp_seq: 0,
    id: session_seq.val,
    pending: [],
    dirty: [],
    deleted: [],
    detach: [],
  }
}

///|
/// How many nested savepoints opened via `begin_nested` are currently active.
pub fn Session::savepoint_depth(self : Session) -> Int {
  self.sp_depth
}

///|
/// Execute a raw statement with bound `params`.
pub fn Session::execute(
  self : Session,
  sql : String,
  params : Array[Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  self.driver.execute(sql, params)
}

///|
/// Run a raw query with bound `params` and return its rows.
pub fn Session::query(
  self : Session,
  sql : String,
  params : Array[Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.driver.query(sql, params)
}

///|
/// Build and run an `Insert` **now**, returning the affected-row count and new
/// rowid. This is the statement-level form: it goes to the driver on this call and
/// never touches the unit of work. To queue a record instead and let `flush` order
/// and emit it, use `add_record`.
///
/// This renders the SQLite/PostgreSQL form (`ON CONFLICT` upserts, `RETURNING`); for
/// a MySQL upsert build the dialect form explicitly —
/// `session.execute(stmt.build_for(Mysql))`.
pub fn Session::add(
  self : Session,
  stmt : Insert,
) -> @moondb.ExecResult raise @moondb.DbError {
  let (sql, params) = stmt.build()
  self.driver.execute(sql, params)
}

///|
/// Build and run a `Select`, returning the matched rows.
pub fn Session::fetch(
  self : Session,
  stmt : Select,
) -> Array[@moondb.Row] raise @moondb.DbError {
  let (sql, params) = stmt.build()
  self.driver.query(sql, params)
}

///|
/// Stream a raw query's rows through a [`@moondb.Cursor`] instead of materialising
/// them — the bounded-memory counterpart to [`query`] (SQLAlchemy's
/// `stream_results`). This seam is synchronous, so only a synchronous driver with
/// incremental fetch streams lazily here: moonsqlite steps its prepared statement
/// row by row. A wire driver's cursor is async and cannot come through here at all
/// — moonpostgres implements `@moondb.AsyncDriver` instead, so it never sits
/// behind a `Session`; MySQL's synchronous adapter falls back to a materialised
/// cursor. For lazy streaming over the wire call `PgConn`/`MysqlConn::query_stream`
/// directly under an event loop.
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
  stmt : Select,
) -> &@moondb.Cursor raise @moondb.DbError {
  let (sql, params) = stmt.build()
  self.driver.query_stream(sql, params)
}

///|
/// A typed streaming cursor: each [`next`](RowStream::next) decodes one row into a
/// record via the model. The record-level counterpart to [`Session::stream`], the
/// streaming form of [`fetch_as`] (SQLAlchemy's `yield_per`).
pub struct RowStream[T] {
  cursor : &@moondb.Cursor
  model : Model[T]
}

///|
/// The next decoded record, or `None` once the result is exhausted.
pub fn[T] RowStream::next(self : RowStream[T]) -> T? raise @moondb.DbError {
  match self.cursor.next() {
    Some(row) => Some(self.model.map_row(row))
    None => None
  }
}

///|
/// Release the underlying cursor early.
pub fn[T] RowStream::close(self : RowStream[T]) -> Unit {
  self.cursor.close()
}

///|
/// Build and stream a `Select`, decoding each row into a `T` on demand — the
/// streaming counterpart to [`fetch_as`].
pub fn[T] Session::stream_as(
  self : Session,
  model : Model[T],
  stmt : Select,
) -> RowStream[T] raise @moondb.DbError {
  let (sql, params) = stmt.build()
  { cursor: self.driver.query_stream(sql, params), model, }
}

///|
/// Build and run an `Update`, returning the affected-row count.
pub fn Session::modify(
  self : Session,
  stmt : Update,
) -> @moondb.ExecResult raise @moondb.DbError {
  let (sql, params) = stmt.build()
  self.driver.execute(sql, params)
}

///|
/// Build and run a `Delete`, returning the affected-row count.
pub fn Session::remove(
  self : Session,
  stmt : Delete,
) -> @moondb.ExecResult raise @moondb.DbError {
  let (sql, params) = stmt.build()
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
  stmt : Update,
  what? : String = "row",
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
/// Flush the unit of work, then commit the current transaction. Queued records reach
/// the database here if nothing has flushed them yet, which is why a caller can add
/// and commit without naming `flush` at all. With an empty queue this is the bare
/// driver commit.
pub fn Session::commit(self : Session) -> Unit raise @moondb.DbError {
  self.flush()
  self.driver.commit()
}

///|
/// Roll back the current transaction, abandoning whatever is still queued and
/// emptying the identity map. The records held there describe rows the rollback has
/// just undone, so keeping them would hand out state the database no longer has.
pub fn Session::rollback(self : Session) -> Unit raise @moondb.DbError {
  self.discard()
  self.driver.rollback()
}

///|
/// Whether `s` is a bare SQL identifier (`[A-Za-z_][A-Za-z0-9_]*`). SAVEPOINT names
/// are identifiers, not bound values, so they cannot be parameterised; validating
/// them keeps the nested-transaction API injection-safe by refusing anything that
/// is not a plain name.
fn is_ident(s : String) -> Bool {
  if s.length() == 0 {
    return false
  }
  for i = 0; i < s.length(); i = i + 1 {
    let c = s[i].to_int()
    let alpha = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
    let digit = c >= 48 && c <= 57
    if !(alpha || (i > 0 && digit)) {
      return false
    }
  }
  true
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
  if !is_ident(name) {
    raise @moondb.QueryError("invalid savepoint name: " + name)
  }
  self.driver.execute("SAVEPOINT " + name, [])
}

///|
/// Roll back to a savepoint (`ROLLBACK TO SAVEPOINT <name>`), undoing everything
/// done since it was opened while keeping the savepoint (and the outer transaction)
/// active. Rejects a non-identifier `name` with `QueryError`.
pub fn Session::rollback_to(
  self : Session,
  name : String,
) -> @moondb.ExecResult raise @moondb.DbError {
  if !is_ident(name) {
    raise @moondb.QueryError("invalid savepoint name: " + name)
  }
  self.driver.execute("ROLLBACK TO SAVEPOINT " + name, [])
}

///|
/// Release a savepoint (`RELEASE SAVEPOINT <name>`), merging its work into the
/// enclosing transaction (or savepoint). Rejects a non-identifier `name`.
pub fn Session::release(
  self : Session,
  name : String,
) -> @moondb.ExecResult raise @moondb.DbError {
  if !is_ident(name) {
    raise @moondb.QueryError("invalid savepoint name: " + name)
  }
  self.driver.execute("RELEASE SAVEPOINT " + name, [])
}

///|
/// A nested transaction opened by `Session::begin_nested`, wrapping one SAVEPOINT
/// whose name and depth the session tracks for you. It is the faithful equivalent
/// of the object SQLAlchemy's `Session.begin_nested()` returns: finish it by
/// `release`-ing (keep the work, merging it into the enclosing transaction) or
/// `rollback`-ing (discard the work since the savepoint). Both are terminal and
/// idempotent — calling either a second time is a no-op — and both decrement the
/// session's savepoint depth.
pub struct Savepoint {
  sess : Session
  name : String
  depth : Int
  mut finished : Bool
}

///|
/// The generated SQL name of this savepoint.
pub fn Savepoint::name(self : Savepoint) -> String {
  self.name
}

///|
/// This savepoint's nesting depth (1 for the outermost `begin_nested`, 2 for one
/// opened inside it, and so on).
pub fn Savepoint::depth(self : Savepoint) -> Int {
  self.depth
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
  self.sp_seq = self.sp_seq + 1
  let name = "moonorm_sp_" + self.sp_seq.to_string()
  self.driver.execute("SAVEPOINT " + name, []) |> ignore
  self.sp_depth = self.sp_depth + 1
  { sess: self, name, depth: self.sp_depth, finished: false, }
}

///|
/// Release this savepoint (`RELEASE SAVEPOINT <name>`), keeping the work done since
/// it opened and merging it into the enclosing transaction. Terminal and idempotent.
/// The SQLAlchemy nested-transaction `commit()`.
pub fn Savepoint::release(self : Savepoint) -> Unit raise @moondb.DbError {
  if self.finished {
    return
  }
  self.sess.driver.execute("RELEASE SAVEPOINT " + self.name, []) |> ignore
  self.finished = true
  self.sess.sp_depth = self.sess.sp_depth - 1
}

///|
/// SQLAlchemy spells "keep the nested work" as `commit()`; this is the alias for
/// [`release`].
pub fn Savepoint::commit(self : Savepoint) -> Unit raise @moondb.DbError {
  self.release()
}

///|
/// Roll back and close this savepoint, discarding everything done since it opened
/// while leaving the enclosing transaction intact. It issues `ROLLBACK TO SAVEPOINT`
/// followed by `RELEASE SAVEPOINT`, so — like SQLAlchemy's nested `rollback()` — the
/// savepoint is terminal afterwards and the depth drops. Terminal and idempotent.
pub fn Savepoint::rollback(self : Savepoint) -> Unit raise @moondb.DbError {
  if self.finished {
    return
  }
  self.sess.driver.execute("ROLLBACK TO SAVEPOINT " + self.name, []) |> ignore
  self.sess.driver.execute("RELEASE SAVEPOINT " + self.name, []) |> ignore
  self.finished = true
  self.sess.sp_depth = self.sess.sp_depth - 1
}

///|
/// A SQL transaction isolation level, in the four-rung ANSI ladder from weakest to
/// strongest. Passed via `TxOptions` to `Session::begin_with`, which renders the
/// backend's `SET TRANSACTION` (or SQLite `PRAGMA`) statement.
pub(all) enum IsolationLevel {
  ReadUncommitted
  ReadCommitted
  RepeatableRead
  Serializable
} derive(Eq)

///|
/// The ANSI keyword for an isolation level (`"READ COMMITTED"`, `"SERIALIZABLE"`, …).
pub fn IsolationLevel::keyword(self : IsolationLevel) -> String {
  match self {
    ReadUncommitted => "READ UNCOMMITTED"
    ReadCommitted => "READ COMMITTED"
    RepeatableRead => "REPEATABLE READ"
    Serializable => "SERIALIZABLE"
  }
}

///|
/// Options for a transaction opened by `Session::begin_with`: an optional
/// `isolation` level and a `read_only` flag. This is the explicit counterpart of
/// SQLAlchemy's `connection.execution_options(isolation_level=…)` — a plain value the
/// session renders into the backend's transaction-characteristics statement.
pub(all) struct TxOptions {
  isolation : IsolationLevel?
  read_only : Bool
}

///|
/// Transaction options with everything defaulted off (backend default isolation,
/// read-write). Set what you need: `{ ..TxOptions::default(), isolation:
/// Some(Serializable) }`.
pub fn TxOptions::default() -> TxOptions {
  { isolation: None, read_only: false, }
}

///|
/// Render these options into the statements that impose them for `dialect`. On
/// PostgreSQL and MySQL that is `SET TRANSACTION ISOLATION LEVEL <level>` and/or `SET
/// TRANSACTION READ ONLY`; on SQLite, which has no such statement, it is
/// `PRAGMA read_uncommitted = 1` for the one weaker level it supports (every other
/// level is SQLite's default serializable behaviour, so nothing is emitted) and
/// `PRAGMA query_only = 1` for read-only. An empty result means the backend's
/// defaults already satisfy the options.
pub fn TxOptions::to_sql(self : TxOptions, dialect : Dialect) -> Array[String] {
  let out : Array[String] = []
  match dialect {
    Sqlite => {
      match self.isolation {
        Some(ReadUncommitted) => out.push("PRAGMA read_uncommitted = 1")
        _ => ()
      }
      if self.read_only {
        out.push("PRAGMA query_only = 1")
      }
    }
    _ => {
      match self.isolation {
        Some(level) =>
          out.push("SET TRANSACTION ISOLATION LEVEL " + level.keyword())
        None => ()
      }
      if self.read_only {
        out.push("SET TRANSACTION READ ONLY")
      }
    }
  }
  out
}

///|
/// Whether `dialect` wants the transaction-characteristics statements issued
/// *before* `BEGIN` rather than after. MySQL's scopeless `SET TRANSACTION` configures
/// the next transaction and must precede it; PostgreSQL's `SET TRANSACTION` runs
/// inside the transaction, after `BEGIN`. SQLite's `PRAGMA`s are connection-level, so
/// issuing them first is fine.
fn tx_opts_before_begin(dialect : Dialect) -> Bool {
  match dialect {
    Postgres => false
    _ => true
  }
}

///|
/// Begin a transaction with explicit isolation / read-only options. It brackets the
/// driver's `begin` with the `SET TRANSACTION` (or `PRAGMA`) statements `opts`
/// renders for `dialect`, ordered so each backend accepts them: before `BEGIN` for
/// MySQL and SQLite, after `BEGIN` for PostgreSQL (see `TxOptions::to_sql`). `dialect`
/// defaults to `Postgres`, whose `SET TRANSACTION ISOLATION LEVEL` spelling is the
/// ANSI-standard one. Commit or roll back with the usual `commit`/`rollback`.
pub fn Session::begin_with(
  self : Session,
  opts : TxOptions,
  dialect? : Dialect = Postgres,
) -> Unit raise @moondb.DbError {
  let stmts = opts.to_sql(dialect)
  if tx_opts_before_begin(dialect) {
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
/// Create the table backing `model` from its declared columns (see
/// `Model::create_table_sql`). With `if_not_exists=true` the DDL is idempotent.
pub fn[T] Session::create_table(
  self : Session,
  model : Model[T],
  if_not_exists? : Bool = false,
) -> @moondb.ExecResult raise @moondb.DbError {
  self.driver.execute(model.create_table_sql(if_not_exists~), [])
}

///|
/// Insert a mapped `record` through its `model` **now**, binding the model's
/// `to_columns` pairs. Returns the affected-row count and new rowid. Nothing is
/// queued and the identity map is not consulted; `add_record` is the unit-of-work
/// counterpart that defers to `flush`.
pub fn[T] Session::insert_record(
  self : Session,
  model : Model[T],
  record : T,
) -> @moondb.ExecResult raise @moondb.DbError {
  let (sql, params) = model.insert_of(record).build()
  self.driver.execute(sql, params)
}

///|
/// Run a `Select` and decode every row into a `T` via `model`. Use it with a
/// `Model::select()` (optionally refined with `where_`/`order_by`) to get records
/// rather than raw `Row`s back.
pub fn[T] Session::fetch_as(
  self : Session,
  model : Model[T],
  stmt : Select,
) -> Array[T] raise @moondb.DbError {
  let (sql, params) = stmt.build()
  model.map_rows(self.driver.query(sql, params))
}

///|
/// Fetch every row of a model's table, decoded into records (`SELECT <cols> FROM
/// <table>`).
pub fn[T] Session::all(
  self : Session,
  model : Model[T],
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
  rel : Relation[S, T],
) -> Array[T] raise @moondb.DbError {
  let (sql, params) = rel.query(source).build()
  rel.target.map_rows(self.driver.query(sql, params))
}

///|
/// Eagerly load the single related record of a N:1 relationship (e.g. a child's
/// parent): the first matching row decoded into a record, or `None` if there is no
/// match. Like `load`, the match value is bound.
pub fn[S, T] Session::load_one(
  self : Session,
  source : S,
  rel : Relation[S, T],
) -> T? raise @moondb.DbError {
  let (sql, params) = rel.query(source).limit(1).build()
  let rows = self.driver.query(sql, params)
  if rows.length() == 0 {
    None
  } else {
    Some(rel.target.map_row(rows[0]))
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
  rel : Relation[S, T],
) -> Array[Array[T]] raise @moondb.DbError {
  let result : Array[Array[T]] = []
  for _ in sources {
    result.push([])
  }
  if sources.length() == 0 {
    return result
  }
  let (sql, params) = rel.batch_query(sources).build()
  let rows = self.driver.query(sql, params)
  // Bucket every fetched child to the sources it belongs to. The child's foreign
  // key lives in the row under `key_column`; a source claims the child when its
  // extracted key equals that value.
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
  result
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
  rel : Relation[S, T],
) -> Array[T?] raise @moondb.DbError {
  let result : Array[T?] = []
  for _ in sources {
    result.push(None)
  }
  if sources.length() == 0 {
    return result
  }
  let (sql, params) = rel.batch_query(sources).build()
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
  self.discard()
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
  rel : ManyToMany[S, T],
) -> Array[T] raise @moondb.DbError {
  let (sql, params) = rel.query(source).build()
  rel.target.map_rows(self.driver.query(sql, params))
}

///|
pub extend LostUpdate with Show::{to_string, output}

///|
pub extend IsolationLevel with Eq::{not_equal, equal}
