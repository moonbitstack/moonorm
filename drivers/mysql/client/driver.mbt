// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A synchronous `@moondb.Driver` over MySQL — the adapter that lets a moondb
/// query layer (moonorm) talk to MySQL through the same contract as the SQLite
/// and Postgres drivers.
///
/// ## The async wall, and what it means here
///
/// moonbitlang/async sockets are asynchronous, but `@moondb.Driver`'s methods
/// are synchronous, and MoonBit forbids calling an `async` function from a
/// non-`async` one. The bridge is `@async.run_async_main`, which spins an event
/// loop, runs an async body to completion, and returns — the same hook the
/// toolchain uses to enter `async fn main`.
///
/// A socket does **not** survive across two such event loops (each tears its
/// file descriptors down; verified empirically), so every `execute`/`query`
/// opens a fresh connection, authenticates, runs its one statement, and closes.
/// That is correct and efficient enough for autocommit work — which is exactly
/// what the moondb roundtrip is — but it means a transaction cannot be held open
/// across separate `Driver` calls. `begin`/`commit`/`rollback` therefore raise a
/// clear error directing callers to the asynchronous [`MysqlConn`] API, which
/// owns its socket for its whole lifetime and brackets real transactions. This
/// is a language constraint, not a shortcut, and it is documented in the README.
pub struct MysqlDriver {
  host : String
  port : Int
  user : String
  password : String
  database : String
}

///|
/// Configure a driver. `host` defaults to loopback, `port` to 3306; `password`
/// and `database` may be empty.
pub fn MysqlDriver::new(
  user~ : String,
  password? : String = "",
  database? : String = "",
  host? : String = "127.0.0.1",
  port? : Int = 3306,
) -> MysqlDriver {
  { host, port, user, password, database, }
}

///|
/// Translate any wire-level or socket error raised inside the event loop onto
/// the coarse `@moondb.DbError` the contract speaks.
fn to_db_error(e : Error) -> @moondb.DbError {
  match e {
    @moondb.Closed => @moondb.Closed
    @moondb.ConnectError(m) => @moondb.ConnectError(m)
    @moondb.QueryError(m) => @moondb.QueryError(m)
    @moondb.TypeError(m) => @moondb.TypeError(m)
    @moonmysql.ServerError(_, _, _)
    | @moonmysql.ProtocolError(_)
    | @moonmysql.UnsupportedError(_) => @moondb.QueryError(e.to_string())
    _ => @moondb.ConnectError(e.to_string())
  }
}

///|
/// Open a fresh connection, run `op` against it, close it, and surface the
/// result (or a mapped `DbError`) back on the synchronous side of the async wall.
fn[T] MysqlDriver::with_conn(
  self : MysqlDriver,
  op : async (MysqlConn) -> T,
) -> T raise @moondb.DbError {
  let slot : Ref[Result[T, @moondb.DbError]] = Ref(Err(@moondb.Closed))
  @async.run_async_main(() => {
    @async.with_task_group(_g => {
      slot.val = try {
        let conn = MysqlConn::connect(
          self.host,
          self.port,
          self.user,
          self.password,
          self.database,
        )
        defer conn.close()
        Ok(op(conn))
      } catch {
        e => Err(to_db_error(e))
      }
    })
  })
  match slot.val {
    Ok(v) => v
    Err(e) => raise e
  }
}

///|
const TXN_UNSUPPORTED : String = "the synchronous @moondb.Driver adapter is autocommit-only: MoonBit's async wall makes each call open a fresh connection, so a transaction cannot span Driver calls — use the async MysqlConn API (begin/commit/rollback) for real transactions (see README)"

///|
pub impl @moondb.Driver for MysqlDriver with fn execute(
  self : MysqlDriver,
  sql : String,
  params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  self.with_conn(conn => conn.execute(sql, params))
}

///|
pub impl @moondb.Driver for MysqlDriver with fn query(
  self : MysqlDriver,
  sql : String,
  params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.with_conn(conn => conn.query(sql, params))
}

///|
pub impl @moondb.Driver for MysqlDriver with fn begin(_self : MysqlDriver) -> Unit raise @moondb.DbError {
  raise @moondb.QueryError(TXN_UNSUPPORTED)
}

///|
pub impl @moondb.Driver for MysqlDriver with fn commit(_self : MysqlDriver) -> Unit raise @moondb.DbError {
  raise @moondb.QueryError(TXN_UNSUPPORTED)
}

///|
pub impl @moondb.Driver for MysqlDriver with fn rollback(_self : MysqlDriver) -> Unit raise @moondb.DbError {
  raise @moondb.QueryError(TXN_UNSUPPORTED)
}

///|
pub impl @moondb.Driver for MysqlDriver with fn close(_self : MysqlDriver) -> Unit {
  // Reconnect-per-call keeps no socket open between calls; nothing to release.

}
