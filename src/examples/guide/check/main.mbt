// The three model styles must answer the same three requests the same way. Compare
// their DDL, SELECT and INSERT, and print the agreed answer for the guide generator.
// A mismatch stops the run, so the guide can never show a style that drifted.

///|
fn main {
  let a = (@annotated.ddl(), @annotated.query(), @annotated.insert())
  let f = (@functional.ddl(), @functional.query(), @functional.insert())
  let c = (@class.ddl(), @class.query(), @class.insert())
  if a != f {
    abort("the annotated and functional models disagree")
  }
  if a != c {
    abort("the annotated and class models disagree")
  }
  println("=== ddl ===")
  println(a.0)
  println("=== query ===")
  println(a.1)
  println("=== insert ===")
  println(a.2)
  println("=== diff ===")
  println(@report.diff())
}
