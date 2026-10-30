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
  depth : Int32
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
pub fn Savepoint::depth(self : Savepoint) -> Int32 {
  self.depth
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
/// The same as [`release`]: keeps the nested work, under the name a reader
/// coming from `COMMIT` looks for.
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
pub fn TxOptions::to_sql(
  self : TxOptions,
  dialect : @query.Dialect,
) -> Array[String] {
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
pub extend IsolationLevel with Eq::{not_equal, equal}
