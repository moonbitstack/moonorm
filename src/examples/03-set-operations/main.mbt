///|
/// Set operations and `DISTINCT`: `UNION` / `UNION ALL` / `INTERSECT` / `EXCEPT`
/// chain a second query onto the first, and a trailing `ORDER BY` / `LIMIT` binds to
/// the whole compound. Each operand carries its own `DISTINCT`; bound values thread
/// through in text order, left operand first.
///
///     moon run examples/03-set-operations
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
  // DISTINCT on a single query.
  let (dsql, _) = @moonorm.select("events").distinct().column("kind").build()
  println("-- distinct")
  println(dsql)

  // UNION ALL keeps duplicates; the trailing ORDER BY / LIMIT apply to the compound.
  let active = @moonorm.select("users")
    .column("id")
    .eq("active", @moondb.Bool(true))
  let staff = @moonorm.select("staff")
    .column("id")
    .where_("role", "=", @moondb.Text("qwq"))
  let (usql, uparams) = active
    .union_all(staff)
    .order_by("id", Asc)
    .limit(233)
    .build()
  println("")
  println("-- union all + compound order/limit")
  println(usql)
  println("params: " + params_str(uparams))

  // INTERSECT (rows in both) and EXCEPT (set difference). Each builder mutates and
  // returns itself, so a fresh pair of operands is built per compound.
  let paid = fn() {
    @moonorm.select("orders")
    .column("user_id")
    .eq("status", @moondb.Text("paid"))
  }
  let shipped = fn() {
    @moonorm.select("orders")
    .column("user_id")
    .eq("status", @moondb.Text("shipped"))
  }
  let (isql, iparams) = paid().intersect(shipped()).build()
  println("")
  println("-- intersect")
  println(isql)
  println("params: " + params_str(iparams))
  let (esql, eparams) = paid().except_(shipped()).build()
  println("")
  println("-- except")
  println(esql)
  println("params: " + params_str(eparams))
}
