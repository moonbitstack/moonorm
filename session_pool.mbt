// The pool-backed session entry (← SQLAlchemy's `sessionmaker(bind=engine)`, Go's
// `db.Conn`): check a connection out of a `@pool.Pool`, run a unit of work on a `Session`
// built over it, and return the connection to the pool afterwards — even if the work raises.
// `Session::new` stays for a caller-owned connection; this is the entry that ties the ORM to
// the connection pool.

///|
/// Run `f` with a `Session` on a connection borrowed from `pool`, returning the connection
/// to the pool when `f` finishes or raises. The unit of work owns its transaction: commit or
/// roll back inside `f` before it returns, since the connection is reused as-is.
pub fn[D : @moondb.Driver, T] Session::with_pool(
  pool : @pool.Pool[D],
  f : (Session) -> T raise,
) -> T raise {
  let conn = pool.acquire()
  defer pool.release(conn)
  f(Session::new(conn))
}
