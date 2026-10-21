///|
/// Joins and aggregation: an inner `JOIN` and a `LEFT JOIN` (each a table plus a raw
/// `ON` predicate), `GROUP BY`, `HAVING` on an aggregate, and the `count()` / `raw()`
/// aggregate projections. The `HAVING` value binds as a `?` exactly like a `WHERE`, so
/// an aggregate filter stays injection-safe.
///
///     moon run examples/02-join-aggregate
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
  let (sql, params) = @moonorm.select("orders")
    .raw("users.name")
    .raw("SUM(orders.total)")
    .count()
    .join("users", "users.id = orders.user_id")
    .eq("orders.status", @moondb.Text("paid"))
    .group_by("users.name")
    .having("SUM(orders.total)", ">", @moondb.Int(23333))
    .order_by("users.name", Asc)
    .build()
  println("-- grouped aggregate with JOIN + HAVING")
  println(sql)
  println("params: " + params_str(params))

  // LEFT JOIN keeps unmatched left rows; the ON predicate is raw identifier SQL.
  let (lsql, lparams) = @moonorm.select("users u")
    .raw("u.name")
    .raw("COUNT(o.id)")
    .left_join("orders o", "o.user_id = u.id")
    .group_by("u.name")
    .having("COUNT(o.id)", "=", @moondb.Int(0))
    .build()
  println("")
  println("-- left join, group, having")
  println(lsql)
  println("params: " + params_str(lparams))
}
