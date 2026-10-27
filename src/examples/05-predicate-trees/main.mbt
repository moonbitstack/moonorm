///|
/// Boolean predicate trees — the parameter-safe `AND` / `OR` / `NOT` grouping the flat
/// `where_` / `eq` chain (always joined by `AND`) cannot express. A `Predicate` composes
/// `Cmp`, `InList`, `Exists`, and nested `And` / `Or` / `Not`; `where_pred` ANDs it with
/// the rest of the `WHERE`. Every comparison binds its value, so `(a = ? OR b = ?)` stays
/// fully parameterised. `Predicate::build` renders one to its fragment and bound values.
///
///     moon run examples/05-predicate-trees
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
  // (name = ? OR name = ?) AND NOT (banned = ?), ANDed with a flat eq().
  let tree : @moonorm.Predicate = And([
    Or([
      Cmp(col="name", op="=", val=@moondb.Text("lfanke")),
      Cmp(col="name", op="=", val=@moondb.Text("heke1228")),
    ]),
    Not(Cmp(col="banned", op="=", val=@moondb.Bool(true))),
  ])
  let (sql, params) = @moonorm.select("users")
    .column("id")
    .eq("active", @moondb.Bool(true))
    .where_pred(tree)
    .build()
  println("-- and/or/not predicate tree")
  println(sql)
  println("params: " + params_str(params))

  // InList renders a parameterised IN; an empty list constant-folds.
  let inpred : @moonorm.Predicate = InList(
    col="id",
    vals=[@moondb.Int(233), @moondb.Int(23333), @moondb.Int(66666)],
    negated=false,
  )
  let (isql, iparams) = inpred.build()
  println("")
  println("-- Predicate::build for an IN list")
  println(isql)
  println("params: " + params_str(iparams))
  let empty_in : @moonorm.Predicate = InList(col="id", vals=[], negated=true)
  let (esql, _) = empty_in.build()
  println("")
  println("-- empty NOT IN constant-folds to always-true")
  println(esql)
}
