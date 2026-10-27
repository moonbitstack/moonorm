///|
/// The core `SELECT` builder: projected columns (`column` / `raw` / `count`), a
/// filter chain (`eq` shorthand plus `where_` with an arbitrary operator), `ORDER BY`
/// in both directions, and `LIMIT` / `OFFSET`. Every bound value leaves the SQL as a
/// `?` and rides in the params list. It closes by rendering the same query off a
/// `Table` descriptor, whose declared columns become the projection.
///
///     moon run examples/01-select-basics
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
  let parts = vals.map(render)
  "[" + parts.join(", ") + "]"
}

///|
#coverage.skip
fn main {
  let (sql, params) = @moonorm.select("users")
    .column("id")
    .column("name")
    .eq("age", @moondb.Int(233))
    .where_("name", "LIKE", @moondb.Text("lfanke%"))
    .order_by("name", Asc)
    .order_by("id", Desc)
    .limit(23333)
    .offset(66666)
    .build()
  println("-- filtered select")
  println(sql)
  println("params: " + params_str(params))

  // A COUNT(*) with no projected columns, and a bare OFFSET (no LIMIT) — the builder
  // synthesises an unbounded LIMIT so SQLite / MySQL accept the grammar.
  let (csql, _) = @moonorm.select("orders").count().offset(23).build()
  println("")
  println("-- count with bare offset")
  println(csql)

  // A `Table` descriptor carries its own column list; `select()` projects them all.
  let orders : @moonorm.Table = {
    name: "orders",
    columns: ["id", "user_id", "total"],
  }
  let (tsql, tparams) = orders
    .select()
    .where_("total", ">", @moondb.Int(66666))
    .build()
  println("")
  println("-- select off a Table descriptor")
  println(tsql)
  println("params: " + params_str(tparams))
}
