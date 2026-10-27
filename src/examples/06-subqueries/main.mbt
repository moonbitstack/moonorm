///|
/// Subquery predicates and CTEs. `with_cte` attaches a `WITH name AS (sub)` whose bound
/// values lead the params list; `where_in` / `where_not_in` take a full subquery;
/// `where_exists` / `where_not_exists` render `[NOT] EXISTS (…)`; and `where_in_values`
/// / `where_not_in_values` take an explicit value list (the set-membership filter a batch
/// load issues). Every subquery's params splice in at the exact point its SQL appears.
///
///     moon run examples/06-subqueries
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
  // A CTE whose value leads the params, then an IN (subquery) referencing it.
  let big = @moonorm.select("orders")
    .column("user_id")
    .where_("total", ">", @moondb.Int(66666))
  let (sql, params) = @moonorm.select("users")
    .column("id")
    .column("name")
    .with_cte("big_spenders", big)
    .eq("active", @moondb.Bool(true))
    .where_in("id", @moonorm.select("big_spenders").column("user_id"))
    .build()
  println("-- CTE + IN (subquery)")
  println(sql)
  println("params: " + params_str(params))

  // EXISTS / NOT EXISTS correlated subqueries.
  let (esql, eparams) = @moonorm.select("users u")
    .raw("u.id")
    .where_exists(
      @moonorm.select("orders o")
      .raw("1")
      .where_("o.user_id", "=", @moondb.Int(233)),
    )
    .where_not_exists(
      @moonorm.select("bans b")
      .raw("1")
      .where_("b.user_id", "=", @moondb.Int(233)),
    )
    .build()
  println("")
  println("-- EXISTS + NOT EXISTS")
  println(esql)
  println("params: " + params_str(eparams))

  // IN over an explicit value list (the batch-load membership filter).
  let (vsql, vparams) = @moonorm.select("heroes")
    .column("name")
    .where_in_values("team_id", [
      @moondb.Int(1),
      @moondb.Int(233),
      @moondb.Int(23333),
    ])
    .build()
  println("")
  println("-- IN (values)")
  println(vsql)
  println("params: " + params_str(vparams))

  // The negated forms: NOT IN (subquery) and NOT IN (values).
  let banned = @moonorm.select("bans").column("user_id")
  let (nsql, nparams) = @moonorm.select("users")
    .column("id")
    .where_not_in("id", banned)
    .where_not_in_values("role", [@moondb.Text("qwq"), @moondb.Text("hhh")])
    .build()
  println("")
  println("-- NOT IN (subquery) + NOT IN (values)")
  println(nsql)
  println("params: " + params_str(nparams))
}
