// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The pool exercised against the @moondb.MockDriver test double. `@moondb.MockDriver::new` is the
// factory; a counter cell records how many real connections the pool opens, which
// is what proves idle reuse (acquire after release must not open a second one) and
// the max_size ceiling. Mutation check: making `acquire` always call `make` instead
// of reusing an idle connection turns the reuse and open-count assertions red.

///|
/// A factory that counts how many connections it has opened, and the pool over it.
/// The count lives in a one-cell array so the closure can mutate it.
fn counting_pool(
  max_size? : Int = 10,
) -> (@moondb.Pool[@moondb.MockDriver], Array[Int]) raise @moondb.DbError {
  let opened = [0]
  let pool = @moondb.Pool::new(
    () => {
      opened[0] = opened[0] + 1
      @moondb.MockDriver::new()
    },
    max_size~,
  )
  (pool, opened)
}

///|
test "pool: an idle connection is reused, not reopened" {
  let (pool, opened) = counting_pool()
  let a = pool.acquire()
  assert_eq(opened[0], 1)
  assert_eq(pool.open_count(), 1)
  assert_eq(pool.idle_count(), 0)
  pool.release(a)
  assert_eq(pool.idle_count(), 1)
  // The second acquire must hand back the released connection — no new open.
  let b = pool.acquire()
  assert_eq(opened[0], 1)
  assert_eq(pool.open_count(), 1)
  assert_eq(pool.idle_count(), 0)
  pool.release(b)
}

///|
test "pool: opens up to max_size distinct connections, then exhausts" {
  let (pool, opened) = counting_pool(max_size=2)
  let a = pool.acquire()
  let b = pool.acquire()
  assert_eq(opened[0], 2)
  assert_eq(pool.open_count(), 2)
  // A third concurrent checkout has no idle connection and no headroom.
  let exhausted = try {
    pool.acquire() |> ignore
    false
  } catch {
    QueryError(_) => true
    _ => false
  }
  assert_eq(exhausted, true)
  // Returning one frees a slot; the next acquire reuses it (still only 2 opened).
  pool.release(a)
  let c = pool.acquire()
  assert_eq(opened[0], 2)
  assert_eq(c.row_count(), 0)
  pool.release(b)
  pool.release(c)
}

///|
test "pool: with_conn releases on the success path" {
  let (pool, _) = counting_pool()
  let n = pool.with_conn(db => {
    db.execute("INSERT INTO t VALUES (?)", [Int(1)]) |> ignore
    db.row_count()
  })
  assert_eq(n, 1)
  // The connection went back to the pool, so it is idle again.
  assert_eq(pool.idle_count(), 1)
  assert_eq(pool.open_count(), 1)
}

///|
test "pool: with_conn releases even when the body raises" {
  let (pool, opened) = counting_pool()
  let raised = try {
    let _ : Unit = pool.with_conn(db => {
      db.execute("x", [Int(1)]) |> ignore
      raise QueryError("boom")
    })
    false
  } catch {
    QueryError(_) => true
    _ => false
  }
  assert_eq(raised, true)
  // Despite the raise, the connection was returned — reusable, not leaked.
  assert_eq(pool.idle_count(), 1)
  assert_eq(opened[0], 1)
}

///|
test "pool: close_all closes idle connections and refuses further acquire" {
  let (pool, _) = counting_pool()
  let a = pool.acquire()
  let b = pool.acquire()
  pool.release(a)
  pool.release(b)
  assert_eq(pool.idle_count(), 2)
  pool.close_all()
  assert_eq(pool.is_closed(), true)
  assert_eq(pool.idle_count(), 0)
  assert_eq(pool.open_count(), 0)
  let refused = try {
    pool.acquire() |> ignore
    false
  } catch {
    Closed => true
    _ => false
  }
  assert_eq(refused, true)
}

///|
test "pool: a connection released after close is closed, not pooled" {
  let (pool, _) = counting_pool()
  let a = pool.acquire()
  pool.close_all()
  // `a` was checked out during close_all, so it survived; releasing it now must
  // close it (open_count drops) rather than re-add it to a closed pool.
  assert_eq(a.is_closed(), false)
  pool.release(a)
  assert_eq(a.is_closed(), true)
  assert_eq(pool.idle_count(), 0)
  assert_eq(pool.open_count(), 0)
}

///|
test "pool: max_size must be positive" {
  let bad = try {
    @moondb.Pool::new(() => @moondb.MockDriver::new(), max_size=0) |> ignore
    false
  } catch {
    QueryError(_) => true
    _ => false
  }
  assert_eq(bad, true)
}

// --- health-check on acquire (pre_ping) ----------------------------------------
//
// A pool with pre_ping probes an idle connection with Driver::ping before reusing
// it. The @moondb.MockDriver's default ping runs `SELECT 1`, which fails once the
// connection is closed — so closing a checked-out connection and releasing it
// simulates a connection the backend dropped underneath the pool. Mutation check:
// deleting the `self.pre_ping && not_alive(conn)` guard in `acquire` makes the pool
// hand the dead connection straight back, turning the two assertions below red.

///|
test "pool pre_ping: a dead idle connection is evicted and a fresh one opened" {
  let opened = [0]
  let pool = @moondb.Pool::new(
    () => {
      opened[0] = opened[0] + 1
      @moondb.MockDriver::new()
    },
    max_size=2,
    pre_ping=true,
  )
  let a = pool.acquire()
  assert_eq(opened[0], 1)
  // The connection dies while checked out, then is returned to the pool, which
  // has no way to know it is dead until it probes.
  a.close()
  pool.release(a)
  assert_eq(pool.idle_count(), 1)
  // pre_ping detects the dead connection, evicts it, and opens a fresh one.
  let b = pool.acquire()
  assert_eq(b.is_closed(), false) // got a live connection, not the dead `a`
  assert_eq(opened[0], 2) // a replacement was actually opened
  assert_eq(pool.idle_count(), 0)
  assert_eq(pool.open_count(), 1) // the dead one was closed, only `b` remains
  pool.release(b)
  pool.close_all()
}

///|
test "pool pre_ping: a healthy idle connection is reused, not reopened" {
  let opened = [0]
  let pool = @moondb.Pool::new(
    () => {
      opened[0] = opened[0] + 1
      @moondb.MockDriver::new()
    },
    pre_ping=true,
  )
  let a = pool.acquire()
  pool.release(a)
  // The connection is alive, so pre_ping passes and the same one comes back.
  let b = pool.acquire()
  assert_eq(opened[0], 1) // no wasteful reopen
  assert_eq(b.is_closed(), false)
  pool.release(b)
  pool.close_all()
}

// --- max lifetime --------------------------------------------------------------
//
// With a fake clock, a connection is retired once its age crosses max_lifetime_ms,
// counting from when it was first opened (not reset by intervening checkouts).
// Mutation check: forcing `is_expired` to always return false makes `opened` stay
// at 1 in the retirement step, turning that assertion red.

///|
test "pool max_lifetime: an aged connection is retired and replaced on acquire" {
  let now = [0L]
  let opened = [0]
  let pool = @moondb.Pool::new(
    () => {
      opened[0] = opened[0] + 1
      @moondb.MockDriver::new()
    },
    max_size=2,
    max_lifetime_ms=100L,
    clock=() => now[0],
  )
  let a = pool.acquire() // born at t=0
  pool.release(a)
  // Still young: reused, not reopened.
  now[0] = 50L
  let b = pool.acquire()
  assert_eq(opened[0], 1)
  pool.release(b)
  // Past its lifetime (age 200 >= 100): retired on acquire, a fresh one opened.
  now[0] = 200L
  let c = pool.acquire()
  assert_eq(opened[0], 2)
  assert_eq(c.is_closed(), false)
  assert_eq(pool.open_count(), 1) // the aged connection was closed
  pool.release(c)
  pool.close_all()
}

///|
test "pool max_lifetime: birth time survives repeated checkouts" {
  let now = [0L]
  let opened = [0]
  let pool = @moondb.Pool::new(
    () => {
      opened[0] = opened[0] + 1
      @moondb.MockDriver::new()
    },
    max_size=1,
    max_lifetime_ms=100L,
    clock=() => now[0],
  )
  let a = pool.acquire() // born at t=0
  now[0] = 40L
  pool.release(a)
  let b = pool.acquire() // age 40, reused
  now[0] = 80L
  pool.release(b)
  // Age is measured from t=0, so at t=120 the connection is past 100 even though it
  // was released only 40ms ago — the birth stamp was not reset by the reuse.
  now[0] = 120L
  let _ = pool.acquire()
  assert_eq(opened[0], 2)
  pool.close_all()
}

// --- non-blocking acquire and the wait budget ----------------------------------

///|
test "pool try_acquire: None when exhausted, Some when a slot is free" {
  let (pool, _) = counting_pool(max_size=1)
  let a = pool.acquire()
  assert_eq(pool.try_acquire() is None, true) // exhausted -> None, no raise
  pool.release(a)
  match pool.try_acquire() {
    Some(c) => pool.release(c)
    None => abort("a freed slot must yield a connection")
  }
  pool.close_all()
}

///|
test "pool: an exhausted acquire reports the configured wait budget" {
  let pool = @moondb.Pool::new(
    () => @moondb.MockDriver::new(),
    max_size=1,
    acquire_timeout_ms=250L,
  )
  let a = pool.acquire()
  let msg = try {
    pool.acquire() |> ignore
    ""
  } catch {
    QueryError(m) => m
    _ => ""
  }
  assert_eq(msg.contains("250"), true)
  assert_eq(msg.contains("exhausted"), true)
  pool.release(a)
  pool.close_all()
}

///|
test "pool: max_lifetime_ms must not be negative" {
  let bad = try {
    @moondb.Pool::new(() => @moondb.MockDriver::new(), max_lifetime_ms=-1L)
    |> ignore
    false
  } catch {
    QueryError(_) => true
    _ => false
  }
  assert_eq(bad, true)
}

///|
/// What a shutdown watches: after `close_all` the idle set is empty, so what remains
/// open is exactly what is still borrowed, and `in_use_count` counts down to zero as
/// those come home.
test "pool: in_use_count is what a @moondb.drain waits on after close_all" {
  let (pool, _) = counting_pool()
  let a = pool.acquire()
  let b = pool.acquire()
  let c = pool.acquire()
  pool.release(c)
  assert_eq(pool.in_use_count(), 2)
  assert_eq(pool.idle_count(), 1)
  pool.close_all()
  // The idle one is gone; the two still out are untouched.
  assert_eq(pool.idle_count(), 0)
  assert_eq(pool.in_use_count(), 2)
  pool.release(a)
  assert_eq(pool.in_use_count(), 1)
  pool.release(b)
  assert_eq(pool.in_use_count(), 0)
  assert_eq(pool.open_count(), 0)
}
