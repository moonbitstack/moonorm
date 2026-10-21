///|
/// A function call as a column expression: `func("coalesce", ["a", "b"])` renders
/// `coalesce(a, b)`. This is SQLAlchemy's `func.*` without the attribute magic — the
/// arguments are identifier-level SQL, rendered verbatim like `Select::raw`, so bind
/// a value by placing a `?` and passing it through the surrounding clause.
pub fn func(name : String, args : Array[String]) -> String {
  name + "(" + args.join(", ") + ")"
}

///|
/// A type conversion: `cast("price", "NUMERIC(10,2)")` renders
/// `CAST(price AS NUMERIC(10,2))`. Identifier-level like `func`.
pub fn cast(expr : String, ty : String) -> String {
  "CAST(" + expr + " AS " + ty + ")"
}

///|
/// A searched `CASE` expression: each `(condition, result)` pair becomes one
/// `WHEN … THEN …`, and a non-empty `else_` the trailing `ELSE`. Identifier-level
/// like `func`. With no branches there is nothing to test, so it folds to `else_`
/// (or `NULL`), which is what an all-branchless `CASE` would evaluate to anyway.
pub fn case_(whens : Array[(String, String)], else_~ : String = "") -> String {
  if whens.length() == 0 {
    return if else_ == "" { "NULL" } else { else_ }
  }
  let parts : Array[String] = []
  for w in whens {
    parts.push("WHEN " + w.0 + " THEN " + w.1)
  }
  let tail = if else_ == "" { "" } else { " ELSE " + else_ }
  "CASE " + parts.join(" ") + tail + " END"
}
