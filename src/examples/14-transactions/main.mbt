///|
/// The transaction bracket — `begin` / `commit` / `rollback` — delegated to the driver.
/// `@moondb.MockDriver` models it faithfully: `begin` snapshots the store, `rollback`
/// restores that snapshot, `commit` keeps the changes. So the row count is a real
/// witness — it climbs inside a transaction, drops back on rollback, and stays put on
/// commit. `in_transaction` reports whether a bracket is open.
///
///     moon run examples/14-transactions
#coverage.skip
fn main {
  try {
    let drv = @moondb.MockDriver::new()
    let sess = @moonorm.Session::new(drv)

    // A baseline row, outside any transaction.
    sess.add(@moonorm.insert("t").set("n", @moondb.Int(233))) |> ignore
    println(
      "start:          rows=\{drv.row_count()} in_tx=\{drv.in_transaction()}",
    )

    // Roll back: everything since begin() is discarded.
    sess.begin()
    sess.add(@moonorm.insert("t").set("n", @moondb.Int(23333))) |> ignore
    sess.add(@moonorm.insert("t").set("n", @moondb.Int(66666))) |> ignore
    println(
      "inside tx:      rows=\{drv.row_count()} in_tx=\{drv.in_transaction()}",
    )
    sess.rollback()
    println(
      "after rollback: rows=\{drv.row_count()} in_tx=\{drv.in_transaction()}",
    )

    // Commit: everything since begin() is kept.
    sess.begin()
    sess.add(@moonorm.insert("t").set("n", @moondb.Int(233))) |> ignore
    sess.commit()
    println(
      "after commit:   rows=\{drv.row_count()} in_tx=\{drv.in_transaction()}",
    )
    sess.close()
  } catch {
    e => println("db error: " + e.to_string())
  }
}
