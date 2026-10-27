///|
/// Nested transactions (SQLAlchemy `begin_nested`): `begin_nested` opens a `SAVEPOINT`,
/// auto-naming it and tracking its depth so callers never spell (or mis-spell) a name;
/// the returned handle finishes with `release` (keep the work) or `rollback` (discard
/// it), both terminal and idempotent, each moving the session's savepoint depth. The
/// raw `savepoint` / `rollback_to` / `release` trio is also shown, along with the
/// identifier guard that refuses a non-identifier name before it reaches the backend.
/// Depth is the session's own bookkeeping, exercised here over `@moondb.MockDriver`.
///
///     moon run examples/15-savepoints
#coverage.skip
fn main {
  try {
    let sess = @moonorm.Session::new(@moondb.MockDriver::new())
    println("depth: \{sess.savepoint_depth()}")

    let outer = sess.begin_nested()
    println(
      "opened \{outer.name()} at depth \{outer.depth()} (session depth \{sess.savepoint_depth()})",
    )
    let inner = sess.begin_nested()
    println(
      "opened \{inner.name()} at depth \{inner.depth()} (session depth \{sess.savepoint_depth()})",
    )

    // Discard the inner nested work, keep the outer.
    inner.rollback()
    println("after inner.rollback -> session depth \{sess.savepoint_depth()}")
    outer.release()
    println("after outer.release  -> session depth \{sess.savepoint_depth()}")

    // Terminal and idempotent: a second finish is a no-op.
    inner.rollback()
    println(
      "inner.rollback again is a no-op -> depth \{sess.savepoint_depth()}",
    )

    // `commit` is SQLAlchemy's spelling for "keep the nested work" — an alias for release.
    let kept = sess.begin_nested()
    kept.commit()
    println(
      "after \{kept.name()}.commit -> session depth \{sess.savepoint_depth()}",
    )

    // The raw trio names its own savepoint.
    sess.savepoint("qwq_sp") |> ignore
    sess.rollback_to("qwq_sp") |> ignore
    sess.release("qwq_sp") |> ignore
    println("raw savepoint/rollback_to/release ran")

    // A non-identifier name is refused up front (savepoint names cannot be bound).
    try {
      sess.savepoint("has space") |> ignore
      println("unexpected: bad savepoint name accepted")
    } catch {
      e => println("rejected bad savepoint name: \{e}")
    }
    sess.close()
  } catch {
    e => println("db error: " + e.to_string())
  }
}
