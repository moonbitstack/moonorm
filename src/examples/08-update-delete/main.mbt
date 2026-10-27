///|
/// The `UPDATE` and `DELETE` builders: multi-column `SET`, a `WHERE` chain, and the
/// `= NULL` -> `IS NULL` fold (three-valued logic never matches `= NULL`, so the
/// builder rewrites it the way SQLAlchemy folds `== None`). Then the same statements
/// run through a `Session` over `@moondb.MockDriver`, which reports an affected-row
/// count. Bound values ride as `?`; a folded NULL predicate carries none.
///
///     moon run examples/08-update-delete
fn render(v : @moondb.Value) -> String {
  match v {
    Null => "Null"
    Bool(b) => "Bool(\{b})"
    Int(n) => "Int(\{n})"
    Int64(n) => "Int64(\{n})"
    Double(d) => "Double(\{d})"
    Text(s) => "Text(\"\{s}\")"
    Blob(b) => "Blob(\{b.length()} bytes)"
  }
}

///|
fn params_str(vals : Array[@moondb.Value]) -> String {
  "[" + vals.map(render).join(", ") + "]"
}

///|
#coverage.skip
fn main {
  let (usql, uparams) = @moonorm.update("heroes")
    .set("name", @moondb.Text("lfanke"))
    .set("age", @moondb.Int(23333))
    .where_("id", "=", @moondb.Int(233))
    .build()
  println("-- update")
  println(usql)
  println("params: " + params_str(uparams))

  // Setting a column to NULL binds; a `= NULL` predicate folds to `IS NULL` and does
  // not bind.
  let (nsql, nparams) = @moonorm.update("heroes")
    .set("team_id", @moondb.Null)
    .where_("team_id", "=", @moondb.Null)
    .build()
  println("")
  println("-- update with NULL fold in WHERE")
  println(nsql)
  println("params: " + params_str(nparams))

  let (dsql, dparams) = @moonorm.delete("heroes")
    .where_("age", "<", @moondb.Int(18))
    .where_("team_id", "!=", @moondb.Null)
    .build()
  println("")
  println("-- delete with != NULL fold")
  println(dsql)
  println("params: " + params_str(dparams))

  // Run UPDATE / DELETE through a Session; the driver returns an ExecResult.
  try {
    let drv = @moondb.MockDriver::new()
    let sess = @moonorm.Session::new(drv)
    sess.add(
      @moonorm.insert("heroes")
      .set("name", @moondb.Text("qwq"))
      .set("age", @moondb.Int(66666)),
    )
    |> ignore
    let up = sess.modify(
      @moonorm.update("heroes")
      .set("age", @moondb.Int(23))
      .where_("age", ">", @moondb.Int(18)),
    )
    println("")
    println("-- Session.modify rows_affected: \{up.rows_affected}")
    let del = sess.remove(
      @moonorm.delete("heroes").where_("age", "<", @moondb.Int(0)),
    )
    println("-- Session.remove rows_affected: \{del.rows_affected}")
    sess.close()
  } catch {
    e => println("db error: " + e.to_string())
  }
}
