// Hybrid attributes: one definition, read as SQL and as a value.
//
//     moon run examples/26-hybrids
//
// A hybrid holds the SQL expression over the columns and the reader that computes the
// same value from a record. The point of defining it once is that a filter written in
// SQL and a check written in MoonBit cannot drift apart; the example prints both
// readings side by side.

///|
struct Person {
  first : String
  last : String
  age : Int32
}

///|
fn person(first : String, last : String, age : Int32) -> Person {
  { first, last, age, }
}

///|
/// Two hybrids over the same record: a concatenation and an arithmetic expression.
fn full_name() -> @moonorm.Hybrid[Person] {
  @moonorm.hybrid("full_name", "{t}.first || ' ' || {t}.last", p => {
    @moondb.Text(p.first + " " + p.last)
  })
}

///|
fn is_adult() -> @moonorm.Hybrid[Person] {
  @moonorm.hybrid("is_adult", "{t}.age >= 18", p => @moondb.Bool(p.age >= 18))
}

///|
fn main {
  run() catch {
    error => println("error: " + error.to_string())
  }
}

///|
fn run() -> Unit raise @moondb.DbError {
  let name = full_name()
  let adult = is_adult()
  println("attribute: " + name.name())
  println("  expression: " + name.expr())
  println("  qualified:  " + name.over("people"))
  println("attribute: " + adult.name())
  println("  expression: " + adult.expr())
  println("")
  // The SQL reading: a predicate and an ordering over the computed value.
  let statement = @moonorm.select("people")
    .where_hybrid(name, "=", @moondb.Text("Ada Lovelace"))
    .order_hybrid(adult, @query.Asc)
    .build()
  println("SQL:")
  println("  " + statement.0)
  println("  parameters: " + statement.1.length().to_string())
  println("")
  // The in-memory reading: the same definition, on records.
  let people = [
    person("Ada", "Lovelace", 36),
    person("Alan", "Turing", 41),
    person("Tim", "Berners-Lee", 17),
  ]
  println("values:")
  for p in people {
    let label = match (name.value(p), adult.value(p)) {
      (Text(full), Bool(adult)) => full + " / adult: " + adult.to_string()
      _ => "unexpected"
    }
    println("  " + label)
  }
  println("")
  // What the SQL predicate selects, computed the in-memory way: the two readings have
  // to agree on which rows match.
  let matching = people.filter(p => {
    name.value(p) == @moondb.Text("Ada Lovelace")
  })
  println("rows the predicate names: \{matching.length()}")
  let adults = people.filter(p => adult.value(p) == @moondb.Bool(true))
  println("rows the age predicate admits: \{adults.length()}")
}
