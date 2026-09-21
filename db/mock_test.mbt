// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A query layer written against the *trait*, not a concrete driver — this is the
/// shape moonorm's session takes. That it type-checks and runs against `@moondb.MockDriver`
/// is the proof that `Driver` is a usable, dispatchable contract.
fn[D : Driver] insert_then_read(
  db : D,
  values : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  db.execute("INSERT INTO t VALUES (?)", values) |> ignore
  db.query("SELECT * FROM t", [])
}

///|
test "driver ping: default probe succeeds on a live connection, fails on a closed one" {
  let db = @moondb.MockDriver::new()
  // The default ping runs `SELECT 1`; the mock answers, so a live connection pings.
  assert_eq(db.ping(), true)
  db.close()
  // On a closed connection the probe's query raises, which the default swallows
  // into a plain `false` rather than propagating.
  assert_eq(db.ping(), false)
}

///|
test "mock driver stores on execute and echoes on query" {
  let db = @moondb.MockDriver::new()
  let rows = insert_then_read(db, [Int(1), Text("a")])
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].int(0), 1)
  assert_eq(rows[0].text(1), "a")
  assert_eq(rows[0].by_name("c1") == Some(Text("a")), true)
  assert_eq(db.row_count(), 1)
}

///|
test "execute reports affected rows and a monotonic last_insert_id" {
  let db = @moondb.MockDriver::new()
  let r1 = db.execute("INSERT", [Int(1)])
  let r2 = db.execute("INSERT", [Int(2)])
  assert_eq(r1.rows_affected, 1L)
  assert_eq(r1.last_insert_id, 1L)
  assert_eq(r2.last_insert_id, 2L)
  assert_eq(db.query("SELECT", []).length(), 2)
}

///|
test "rollback restores the pre-begin snapshot, commit keeps changes" {
  let db = @moondb.MockDriver::new()
  db.execute("INSERT", [Int(1)]) |> ignore
  db.begin()
  assert_eq(db.in_transaction(), true)
  db.execute("INSERT", [Int(2)]) |> ignore
  db.execute("INSERT", [Int(3)]) |> ignore
  assert_eq(db.row_count(), 3)
  db.rollback()
  assert_eq(db.row_count(), 1) // the two in-transaction inserts are undone
  assert_eq(db.in_transaction(), false)

  // Commit path keeps the work.
  db.begin()
  db.execute("INSERT", [Int(9)]) |> ignore
  db.commit()
  assert_eq(db.row_count(), 2)
}

///|
test "nested transactions snapshot independently" {
  let db = @moondb.MockDriver::new()
  db.begin()
  db.execute("INSERT", [Int(1)]) |> ignore
  db.begin()
  db.execute("INSERT", [Int(2)]) |> ignore
  db.rollback() // undoes only the inner insert
  assert_eq(db.row_count(), 1)
  db.commit() // keeps the outer insert
  assert_eq(db.row_count(), 1)
  assert_eq(db.in_transaction(), false)
}

///|
fn raises_query_error(f : () -> Unit raise @moondb.DbError) -> Bool {
  try {
    f()
    false
  } catch {
    QueryError(_) => true
    _ => false
  }
}

///|
test "commit or rollback with no open transaction raises QueryError" {
  let db = @moondb.MockDriver::new()
  assert_eq(raises_query_error(() => db.commit()), true)
  assert_eq(raises_query_error(() => db.rollback()), true)
}

///|
fn raises_closed(f : () -> Unit raise @moondb.DbError) -> Bool {
  try {
    f()
    false
  } catch {
    Closed => true
    _ => false
  }
}

///|
test "operations after close raise Closed, close is idempotent" {
  let db = @moondb.MockDriver::new()
  db.close()
  assert_eq(db.is_closed(), true)
  db.close() // idempotent, does not raise
  assert_eq(raises_closed(() => db.execute("INSERT", []) |> ignore), true)
  assert_eq(raises_closed(() => db.query("SELECT", []) |> ignore), true)
  assert_eq(raises_closed(() => db.begin()), true)
}
