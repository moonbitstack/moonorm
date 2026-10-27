///|
/// Window functions: `<expr> OVER (PARTITION BY … ORDER BY …)`, optionally aliased.
/// A window computes over a frame of rows without collapsing them, so each `window`
/// call adds one more projected column. The expression, partitions, and ordering are
/// identifier-level SQL — they name columns and functions, never bound values, so they
/// render verbatim and carry no params.
///
///     moon run examples/04-window-functions
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
  // ROW_NUMBER over a partition, aliased, alongside a running SUM.
  let (sql, params) = @moonorm.select("sales")
    .column("region")
    .column("amount")
    .window(
      "ROW_NUMBER()",
      partition_by=["region"],
      order_by=[("amount", Desc)],
      as_="rn",
    )
    .window("SUM(amount)", partition_by=["region"], as_="region_total")
    .where_("amount", ">", @moondb.Int(233))
    .build()
  println("-- partitioned window functions")
  println(sql)
  println("params: " + params_str(params))

  // An empty partition/order yields one unordered window over the whole result.
  let (gsql, _) = @moonorm.select("sales")
    .raw("amount")
    .window("RANK()")
    .build()
  println("")
  println("-- window over the whole result")
  println(gsql)
}
