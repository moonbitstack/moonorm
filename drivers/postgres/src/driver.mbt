// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The parameters needed to reach a PostgreSQL backend — a connection descriptor,
/// not a connection. [`connect`](PgDriver::connect) opens the live [`PgConn`],
/// which is the thing that implements the driver seam.
///
/// It exists so a caller can carry connection settings around (a config value, a
/// pool factory) and open a connection from them on demand, the way a DSN string
/// works elsewhere.
pub struct PgDriver {
  host : String
  port : Int32
  user : String
  password : String
  database : String
}

///|
/// Build a connection descriptor. Does not connect: PostgreSQL I/O is async, so
/// the connection is opened by [`connect`](PgDriver::connect) inside an event loop.
pub fn PgDriver::new(
  host~ : String,
  port~ : Int32 = 5432,
  user~ : String,
  password~ : String = "",
  database~ : String,
) -> PgDriver {
  { host, port, user, password, database, }
}

///|
/// Open the connection this descriptor points at. Call it inside an event loop
/// (`async test` / `async fn main`); the returned [`PgConn`] is an
/// [`@moondb.AsyncDriver`].
pub async fn PgDriver::connect(self : PgDriver) -> PgConn raise DbError {
  PgConn::connect(self.host, self.port, self.user, self.password, self.database)
}

// The @moondb.AsyncDriver conformance. It is a direct delegation to PgConn's own
// methods rather than an adapter over something else: PgConn *is* the connection,
// and its API was already the shape of the seam. Postgres has no heartbeat cheaper
// than the trait's default `SELECT 1`, so `ping` is left to the default.

///|
/// Run a non-row statement with bound `params`.
pub impl @moondb.AsyncDriver for PgConn with fn execute(
  self : PgConn,
  sql : String,
  params : Array[Value],
) -> ExecResult raise DbError {
  PgConn::execute(self, sql, params)
}

///|
/// Run a row-returning statement with bound `params`, materialising every row.
pub impl @moondb.AsyncDriver for PgConn with fn query(
  self : PgConn,
  sql : String,
  params : Array[Value],
) -> Array[Row] raise DbError {
  PgConn::query(self, sql, params)
}

///|
/// Stream the statement's rows off the wire on demand. This overrides the trait
/// default (which materialises into an [`@moondb.AsyncArrayCursor`]) with the real
/// incremental cursor, so a large result is consumed in bounded memory.
pub impl @moondb.AsyncDriver for PgConn with fn query_stream(
  self : PgConn,
  sql : String,
  params : Array[Value],
) -> &@moondb.AsyncCursor raise DbError {
  PgConn::query_stream(self, sql, params)
}

///|
/// Begin an explicit transaction.
pub impl @moondb.AsyncDriver for PgConn with fn begin(self : PgConn) -> Unit raise DbError {
  PgConn::begin(self)
}

///|
/// Commit the current transaction.
pub impl @moondb.AsyncDriver for PgConn with fn commit(self : PgConn) -> Unit raise DbError {
  PgConn::commit(self)
}

///|
/// Roll back the current transaction.
pub impl @moondb.AsyncDriver for PgConn with fn rollback(self : PgConn) -> Unit raise DbError {
  PgConn::rollback(self)
}

///|
/// Send Terminate and close the socket; idempotent.
pub impl @moondb.AsyncDriver for PgConn with fn close(self : PgConn) -> Unit {
  PgConn::close(self)
}

///|
/// Yield the next row read off the wire, or `None` at the end of the result.
pub impl @moondb.AsyncCursor for PgRowStream with fn next(self : PgRowStream) -> Row? raise DbError {
  PgRowStream::next(self)
}

///|
/// Abandon the stream, draining the unread result so the connection can run the
/// next statement. The seam's `close` does not raise, so a failed drain is
/// swallowed — but the stream is then left un-finished on purpose, which keeps the
/// connection's streaming guard set and makes the next statement refuse rather than
/// read this result's leftovers.
pub impl @moondb.AsyncCursor for PgRowStream with fn close(self : PgRowStream) -> Unit {
  PgRowStream::close(self) catch {
    _ => ()
  }
}
