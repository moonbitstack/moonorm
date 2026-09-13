// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The contract every database backend implements and every query layer is written
/// against — the seam moondb exists to define. It is the MoonBit transliteration of
/// Go's `database/sql/driver.Conn`/`Execer`/`Queryer` and Python's DB-API 2.0
/// `Connection`/`Cursor`, reduced to the smallest set of operations a relational
/// backend must offer.
///
/// ## The binding contract
///
/// `execute` and `query` both take `(sql, params)`. `sql` carries **positional
/// placeholders** and `params` supplies one [`Value`] per placeholder, in order.
/// A driver is expected to bind values out-of-band rather than interpolate them
/// into the SQL text. A driver that cannot — the MySQL text protocol has no
/// out-of-band binding until prepared statements land — has to escape for the
/// server's actual `sql_mode`, and must say so in its own documentation.
///
/// The placeholder token itself is dialect-specific and chosen by the driver
/// (SQLite/MySQL use `?`, PostgreSQL uses `$1`, `$2`, …); a query layer that emits
/// SQL for a given backend uses that backend's token. moondb fixes the *calling
/// convention* (ordered params array), not the spelling.
///
/// * `execute` runs a statement that returns no rows (INSERT/UPDATE/DELETE/DDL) and
///   reports an [`ExecResult`].
/// * `query` runs a statement that returns rows and materialises every [`Row`].
/// * `begin` / `commit` / `rollback` bracket an explicit transaction. Nesting
///   (savepoints), isolation levels, and read-only hints are driver concerns layered
///   on top; the base contract is the three flat operations.
/// * `close` releases the connection. It does not raise: closing is best-effort and
///   idempotent, matching Go's `io.Closer` discipline for connections.
///
/// This trait is `pub(open)` so out-of-tree drivers (moonsqlite, moonpostgres,
/// moonmysql, …) can implement it. A future prepared-`Stmt` handle and a streaming
/// `Rows` cursor are noted in the README roadmap; v0.1 fixes exactly the operations
/// below so the contract everything pins to stays small and stable.
pub(open) trait Driver {
  /// Run a non-row statement with bound `params`; report rows changed and last id.
  fn execute(Self, String, Array[Value]) -> ExecResult raise DbError
  /// Run a row-returning statement with bound `params`; materialise every row.
  fn query(Self, String, Array[Value]) -> Array[Row] raise DbError
  /// Stream a row-returning statement's rows through a [`Cursor`] instead of
  /// materialising them — the bounded-memory counterpart to `query`, for large
  /// results (SQLAlchemy's `stream_results`). The default wraps `query`'s array in
  /// an [`ArrayCursor`]; a driver with incremental fetch overrides it with a live
  /// cursor over its prepared statement or wire.
  fn query_stream(Self, String, Array[Value]) -> &Cursor raise DbError = _
  /// Begin an explicit transaction.
  fn begin(Self) -> Unit raise DbError
  /// Commit the current transaction.
  fn commit(Self) -> Unit raise DbError
  /// Roll back the current transaction.
  fn rollback(Self) -> Unit raise DbError
  /// Release the underlying connection (best-effort, idempotent).
  fn close(Self) -> Unit
  /// Cheaply check the connection is still usable — the liveness probe a pool runs
  /// before handing an idle connection back (SQLAlchemy's `pool_pre_ping`, Go's
  /// `driver.Pinger`). It returns `false` rather than raising, so a broken
  /// connection is a plain "unhealthy" verdict the caller can act on. The default
  /// issues the universally accepted `SELECT 1` and reports whether it round-trips;
  /// a driver whose backend has a cheaper heartbeat (or none) overrides it.
  fn ping(Self) -> Bool = _
}

///|
/// Default `ping`: run `SELECT 1` and report success. Any failure — a dropped
/// socket, a closed handle, a protocol error — is swallowed into `false` so the
/// probe never raises. `SELECT 1` is a no-side-effect statement every SQL backend
/// accepts, which is exactly why connection pools use it as their heartbeat.
impl Driver with fn ping(self : Self) -> Bool {
  try {
    self.query("SELECT 1", []) |> ignore
    true
  } catch {
    _ => false
  }
}

///|
/// Default `query_stream`: materialise via `query`, then hand back an
/// [`ArrayCursor`] over the result. It honours the [`Cursor`] interface (rows are
/// pulled one at a time) without the memory bound a native incremental cursor
/// gives; a driver that can fetch rows lazily overrides this.
impl Driver with fn query_stream(
  self : Self,
  sql : String,
  params : Array[Value],
) -> &Cursor raise DbError {
  ArrayCursor::new(self.query(sql, params))
}
