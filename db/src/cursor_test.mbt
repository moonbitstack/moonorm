// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "query_stream default cursor yields exactly what query returns" {
  let drv = @moondb.MockDriver::new()
  drv.execute("", [Int(1)]) |> ignore
  drv.execute("", [Int(2)]) |> ignore
  drv.execute("", [Int(3)]) |> ignore
  let materialised = drv.query("", [])
  let streamed = @moondb.drain(drv.query_stream("", []))
  assert_eq(streamed.length(), 3)
  assert_eq(streamed.length(), materialised.length())
  let mut same = true
  for i in 0..<streamed.length() {
    if !(streamed[i].values == materialised[i].values) {
      same = false
    }
  }
  assert_eq(same, true)
}

///|
test "ArrayCursor advances in order then reports exhaustion" {
  let cur = @moondb.ArrayCursor::new([
    { columns: ["c0"], values: [Int(10)], },
    { columns: ["c0"], values: [Int(20)], },
  ])
  let first = cur.next()
  assert_eq(first is Some(_), true)
  guard first is Some(r0) else { fail("cursor should yield a first row") }
  assert_eq(r0.values[0] == Int(10), true)
  assert_eq(cur.next() is Some(_), true)
  assert_eq(cur.next() is None, true)
  // Idempotent past the end and after an explicit close.
  cur.close()
  assert_eq(cur.next() is None, true)
}
