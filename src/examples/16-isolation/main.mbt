///|
/// Transaction isolation & read-only options: `IsolationLevel::keyword` gives the ANSI
/// keyword for each of the four rungs; `TxOptions::to_sql` renders them into the
/// per-dialect statements that impose them (`SET TRANSACTION ISOLATION LEVEL …` on
/// PostgreSQL/MySQL, a `PRAGMA` on SQLite, nothing when the backend default already
/// satisfies the request); and `begin_with` issues those around the driver's
/// transaction bracket, ordered so each backend accepts them.
///
///     moon run examples/16-isolation
#coverage.skip
fn main {
  println("-- IsolationLevel keywords")
  let levels : Array[@moonorm.IsolationLevel] = [
    ReadUncommitted,
    ReadCommitted,
    RepeatableRead,
    Serializable,
  ]
  for lvl in levels {
    println("  \{lvl.keyword()}")
  }

  // Serializable rendered per dialect.
  let serializable : @moonorm.TxOptions = {
    isolation: Some(Serializable),
    read_only: false,
  }
  println("")
  println(
    "-- Serializable, PostgreSQL: " + serializable.to_sql(Postgres).join(" | "),
  )
  println(
    "-- Serializable, MySQL:      " + serializable.to_sql(Mysql).join(" | "),
  )

  // Read-only + the one weaker level SQLite models (via PRAGMA).
  let ro : @moonorm.TxOptions = {
    isolation: Some(ReadUncommitted),
    read_only: true,
  }
  println(
    "-- ReadUncommitted+read_only, SQLite:     " + ro.to_sql(Sqlite).join(" | "),
  )
  println(
    "-- ReadUncommitted+read_only, PostgreSQL: " +
    ro.to_sql(Postgres).join(" | "),
  )

  // Defaults render nothing — the backend's own defaults already suffice.
  let defaults = @moonorm.TxOptions::default()
  println("-- defaults, SQLite: [" + defaults.to_sql(Sqlite).join(" | ") + "]")

  // begin_with issues those statements around the transaction bracket.
  try {
    let drv = @moondb.MockDriver::new()
    let sess = @moonorm.Session::new(drv)
    sess.begin_with(serializable, dialect=Postgres)
    sess.add(@moonorm.insert("t").set("n", @moondb.Int(233))) |> ignore
    sess.commit()
    println("")
    println(
      "begin_with(Serializable) + commit ran; in_tx=\{drv.in_transaction()}",
    )
    sess.close()
  } catch {
    e => println("db error: " + e.to_string())
  }
}
