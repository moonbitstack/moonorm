// The pool-backed session entry, checked with a counting factory over the real pool.

///|
test "session with_pool reuses one pooled connection across units of work" {
  let created = [0]
  let pool : @pool.Pool[@moondb.MockDriver] = @pool.Pool::new(() => {
    created[0] = created[0] + 1
    @moondb.MockDriver::new()
  })
  let a = Session::with_pool(pool, _s => 1)
  let b = Session::with_pool(pool, _s => 2)
  assert_eq(a, 1)
  assert_eq(b, 2)
  // The second unit of work reused the first's released connection: opened once, idle after.
  assert_eq(created[0], 1)
  assert_eq(pool.idle_count(), 1)
}
