// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A fixed-ceiling connection pool over any [`Driver`]. Opening a database
/// connection is expensive — a TCP handshake and auth round trip for a networked
/// backend — so a server hands out a small set of connections and reuses them
/// instead of opening one per request. This is the moondb counterpart of Go's
/// `sql.DB` connection pool and SQLAlchemy's `QueuePool`.
///
/// The pool is generic in the concrete driver `D` rather than holding
/// `&Driver` trait objects, so `acquire` gives back the real driver type and a
/// caller keeps access to backend-specific methods (SQLite's `exec_script`, a
/// driver's prepared-statement handle). `new` takes a `make` factory that opens
/// one fresh connection; the pool calls it only when no idle connection is
/// available and the open count is still below `max_size`.
///
/// Beyond plain reuse, the pool keeps a connection healthy over its lifetime,
/// matching the knobs both `database/sql` and SQLAlchemy's `QueuePool` expose:
///
/// * **pre-ping** (`pre_ping`) — before an idle connection is handed back it is
///   probed with [`Driver::ping`]; a connection that fails the probe is closed and
///   skipped, so a caller never receives a connection the backend has already
///   dropped. This is SQLAlchemy's `pool_pre_ping`.
/// * **max lifetime** (`max_lifetime_ms`) — a connection older than this is retired
///   on acquire and replaced with a fresh one, so long-lived pools recycle
///   connections a load balancer or the server may have aged out. This is Go's
///   `SetConnMaxLifetime`. Age is measured with an injected `clock`, exactly as
///   `database/sql` swaps `nowFunc` in tests; the default clock disables the check.
/// * **acquire timeout** (`acquire_timeout_ms`) — the wait budget an exhausted
///   acquire is allowed. See the note on synchrony below.
///
/// It is synchronous and single-threaded by design — moondb's base contract is
/// sync, and MoonBit's pure backends have no shared-memory threads — so `acquire`
/// never truly blocks: nothing else can return a connection while one call waits.
/// A request that finds the pool exhausted therefore fails immediately rather than
/// sleeping; `acquire_timeout_ms` is carried into that failure's message and is the
/// budget a driver running on an async runtime honours when it layers real waiting
/// on top. Use [`try_acquire`] for the non-raising "give me one only if free" path.
/// The reuse, ceiling, health, and lifecycle bookkeeping all live here.
///
/// The counting is moonpool's `Pool`: live, idle and lent, each lent connection's
/// birth recognised on its way back so `max_lifetime` counts from creation. This
/// type adds only what needs a driver — opening, closing, probing.
pub struct Pool[D] {
  priv make : () -> D raise @moondb.DbError
  priv books : @moonpool.Pool[D]
  priv max_size : Int
  priv max_lifetime_ms : Int64
  priv pre_ping : Bool
  priv acquire_timeout_ms : Int64
  priv clock : () -> Int64
  priv mut closed : Bool
}

///|
/// Build a pool whose connections come from `make`.
///
/// * `max_size` caps how many connections may be open at once (in use plus idle);
///   it defaults to 10, the ceiling Go's `database/sql` uses out of the box, and
///   must be positive.
/// * `max_lifetime_ms` retires a connection older than this many milliseconds on
///   acquire (`0`, the default, means no age limit). Enforcing it requires a real
///   `clock`; with the default clock every connection reads as age `0`.
/// * `pre_ping` turns on the [`Driver::ping`] health probe before an idle
///   connection is reused (off by default).
/// * `acquire_timeout_ms` records the wait budget for an exhausted acquire; `0`
///   (the default) means "fail immediately". In this synchronous pool the wait is
///   always degenerate (see the type doc), so the value serves the error message
///   and an async layer above.
/// * `clock` returns a monotonically non-decreasing millisecond reading and exists
///   so `max_lifetime` is testable and portable; it defaults to a constant `0`,
///   which disables age-based retirement.
pub fn[D] Pool::new(
  make : () -> D raise @moondb.DbError,
  max_size? : Int = 10,
  max_lifetime_ms? : Int64 = 0,
  pre_ping? : Bool = false,
  acquire_timeout_ms? : Int64 = 0,
  clock? : () -> Int64 = fn() { 0L },
) -> Pool[D] raise @moondb.DbError {
  if max_size <= 0 {
    raise QueryError(
      "pool max_size must be positive, got " + max_size.to_string(),
    )
  }
  if max_lifetime_ms < 0L {
    raise QueryError("pool max_lifetime_ms must not be negative")
  }
  // No cap on idle connections and no idle timeout: this pool keeps every
  // connection it opened until it ages out, fails a probe, or the pool closes.
  let limits = @moonpool.Limits::new(
    size=max_size,
    idle=0,
    keep=@moonpool.forever,
    life=@moondate.Span::new(millis=max_lifetime_ms),
  )
  {
    make,
    books: @moonpool.Pool::new(limits~),
    max_size,
    max_lifetime_ms,
    pre_ping,
    acquire_timeout_ms,
    clock,
    closed: false,
  }
}

///|
/// How many connections are currently idle (checked in and reusable).
pub fn[D] Pool::idle_count(self : Pool[D]) -> Int {
  self.books.idle()
}

///|
/// How many connections are checked out right now. A shutdown that wants to wait for
/// borrowed connections to come home polls this after `close_all`: the close empties
/// the idle set, so what is left is exactly what is still in use.
pub fn[D] Pool::in_use_count(self : Pool[D]) -> Int {
  self.books.busy()
}

///|
/// How many connections the pool has open in total: those checked out plus those
/// sitting idle. Never exceeds `max_size`.
pub fn[D] Pool::open_count(self : Pool[D]) -> Int {
  self.books.live()
}

///|
/// The pool's ceiling on simultaneously open connections.
pub fn[D] Pool::max_size(self : Pool[D]) -> Int {
  self.max_size
}

///|
/// The configured maximum connection lifetime in milliseconds (`0` = unlimited).
pub fn[D] Pool::max_lifetime_ms(self : Pool[D]) -> Int64 {
  self.max_lifetime_ms
}

///|
/// Whether the pre-ping health probe is enabled.
pub fn[D] Pool::pre_ping(self : Pool[D]) -> Bool {
  self.pre_ping
}

///|
/// The configured acquire wait budget in milliseconds (`0` = fail immediately).
pub fn[D] Pool::acquire_timeout_ms(self : Pool[D]) -> Int64 {
  self.acquire_timeout_ms
}

///|
/// Whether [`close_all`] has been called.
pub fn[D] Pool::is_closed(self : Pool[D]) -> Bool {
  self.closed
}

///|
/// The clock in the unit moonpool counts in.
fn[D] Pool::now(self : Pool[D]) -> Int64 {
  (self.clock)() * 1_000_000L
}

///|
/// Take a connection: reuse an idle one if the pool has a healthy, unexpired one
/// (the common path, avoiding a fresh handshake), otherwise open a new one through
/// `make` as long as the open count is below `max_size`.
///
/// An idle connection past `max_lifetime_ms`, or one that fails the [`Driver::ping`]
/// probe when `pre_ping` is on, is closed and dropped rather than handed back; the
/// pool then tries the next idle connection or opens a fresh one. Raises
/// `QueryError` if the pool is exhausted (all `max_size` connections are checked
/// out) or [`Closed`] if it has been closed. The caller must return the connection
/// with [`release`] — or use [`with_conn`], which does so even on error.
pub fn[D : @moondb.Driver] Pool::acquire(
  self : Pool[D],
) -> D raise @moondb.DbError {
  match self.next() {
    Some(conn) => conn
    None => {
      let budget = if self.acquire_timeout_ms > 0L {
        "; wait timed out after " + self.acquire_timeout_ms.to_string() + "ms"
      } else {
        ""
      }
      raise QueryError(
        "connection pool exhausted (max_size=" +
        self.max_size.to_string() +
        ")" +
        budget,
      )
    }
  }
}

///|
/// Take a connection only if one is immediately available — an idle one or fresh
/// headroom under `max_size` — returning `None` instead of raising when the pool
/// is exhausted. This is the non-blocking counterpart of [`acquire`]: it never
/// reports the exhaustion case as an error, so a caller can choose to shed load or
/// retry. Health and lifetime eviction apply exactly as in `acquire`; a genuine
/// failure while opening a fresh connection (the `make` factory raising) still
/// propagates.
pub fn[D : @moondb.Driver] Pool::try_acquire(
  self : Pool[D],
) -> D? raise @moondb.DbError {
  self.next()
}

///|
/// A healthy connection, idle or new, or `None` when every one is lent out.
///
/// An idle connection past `max_lifetime_ms`, or one that fails the probe when
/// `pre_ping` is on, is closed and forgotten, and the next is tried; each one closed
/// frees the room a fresh one is then opened in.
fn[D : @moondb.Driver] Pool::next(self : Pool[D]) -> D? raise @moondb.DbError {
  if self.closed {
    raise Closed
  }
  for ;; {
    match self.books.take(self.now()) {
      Ready(conn) =>
        if self.pre_ping && not_alive(conn) {
          conn.close()
          self.books.drop(conn)
        } else {
          return Some(conn)
        }
      Stale(conn) => conn.close()
      Make => {
        // A factory that fails must give the room back, or one bad connect
        // would shrink the pool for good.
        errdefer self.books.unmade()
        let conn = (self.make)()
        self.books.made(conn, self.now())
        return Some(conn)
      }
      Wait => return None
    }
  }
}

///|
/// Return a connection to the idle set so a later [`acquire`] can reuse it,
/// preserving the birth time it was opened with so `max_lifetime` keeps counting
/// from creation rather than resetting on every checkout. A connection released
/// back into a closed pool is closed immediately rather than pooled, so no handle
/// outlives `close_all`.
pub fn[D : @moondb.Driver] Pool::release(self : Pool[D], conn : D) -> Unit {
  if self.closed {
    self.books.drop(conn)
    conn.close()
    return
  }
  let _ = self.books.give(conn, self.now())
}

///|
/// Run `f` with a pooled connection, returning it afterwards whether `f` returns
/// or raises. This is the leak-proof way to use the pool: the `release` happens
/// on every path, so a raising query never strands a connection checked out.
pub fn[D : @moondb.Driver, R] Pool::with_conn(
  self : Pool[D],
  f : (D) -> R raise @moondb.DbError,
) -> R raise @moondb.DbError {
  let conn = self.acquire()
  defer self.release(conn)
  f(conn)
}

///|
/// Close every idle connection and mark the pool closed. Connections still
/// checked out are not touched — each is closed as it is [`release`]d back. After
/// this, `acquire` raises `Closed`. Idempotent.
///
/// This is the graceful half of a shutdown: nothing in flight is cut off. To wait
/// for the rest, poll [`in_use_count`] until it reaches zero — this pool is
/// synchronous, so the waiting belongs to whatever async layer owns it.
pub fn[D : @moondb.Driver] Pool::close_all(self : Pool[D]) -> Unit {
  for conn in self.books.close() {
    conn.close()
  }
  self.closed = true
}

///|
/// Whether a connection fails its [`Driver::ping`] health probe. Factored out so
/// the eviction test can target exactly this predicate.
fn[D : @moondb.Driver] not_alive(conn : D) -> Bool {
  !conn.ping()
}
