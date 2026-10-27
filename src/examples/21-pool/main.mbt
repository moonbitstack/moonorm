///|
/// The connection pool (`@pool.Pool`, SQLAlchemy's `QueuePool` / Go's `database/sql`):
/// `acquire` / `release` check a connection out and back, reusing idle ones;
/// `try_acquire` returns `None` instead of raising when the pool is exhausted;
/// `with_conn` runs a closure with a borrowed connection and returns it even on error;
/// and the pool exposes its knobs (`max_size`, `pre_ping`, `max_lifetime_ms`,
/// `acquire_timeout_ms`, `idle_count`, `open_count`). `Session::with_pool` ties the ORM
/// to the pool — a unit of work on a `Session` over a borrowed connection.
///
///     moon run examples/21-pool
#coverage.skip
fn main {
  try {
    let pool : @pool.Pool[@moondb.MockDriver] = @pool.Pool::new(
      () => @moondb.MockDriver::new(),
      max_size=2,
      pre_ping=true,
    )
    println(
      "pool: max_size=\{pool.max_size()} pre_ping=\{pool.pre_ping()} idle=\{pool.idle_count()} open=\{pool.open_count()}",
    )

    // Acquire, use, release — the connection returns to the idle set for reuse.
    let c1 = pool.acquire()
    c1.execute("INSERT INTO t (n) VALUES (?)", [@moondb.Int(233)]) |> ignore
    println(
      "after acquire: open=\{pool.open_count()} idle=\{pool.idle_count()}",
    )
    pool.release(c1)
    println(
      "after release: open=\{pool.open_count()} idle=\{pool.idle_count()}",
    )

    // Exhaust the pool (max_size=2), then try_acquire yields None rather than raising.
    let a = pool.acquire()
    let b = pool.acquire()
    match pool.try_acquire() {
      Some(_) => println("unexpected: got a third connection")
      None => println("try_acquire on an exhausted pool -> None")
    }
    pool.release(a)
    pool.release(b)

    // with_conn borrows and returns a connection around a closure.
    let rows = pool.with_conn(d => d.query("SELECT 1", []).length())
    println("with_conn ran, query saw \{rows} rows")

    // Session::with_pool: a unit of work on a Session over a borrowed connection.
    let stored = @moonorm.Session::with_pool(pool, sess => {
      sess.add(@moonorm.insert("t").set("n", @moondb.Int(23333))) |> ignore
      sess.query("SELECT * FROM t", []).length()
    })
    println("with_pool unit-of-work saw \{stored} rows")
    println(
      "lifetime_ms=\{pool.max_lifetime_ms()} acquire_timeout_ms=\{pool.acquire_timeout_ms()} closed=\{pool.is_closed()}",
    )
    pool.close_all()
    println(
      "after close_all: open=\{pool.open_count()} closed=\{pool.is_closed()}",
    )
  } catch {
    e => println("db error: " + e.to_string())
  }
}
