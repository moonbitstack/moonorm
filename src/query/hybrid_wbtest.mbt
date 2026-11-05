///|
/// A record with the two columns a name is built from, so the hybrid can be read both
/// ways without a database.
#derive(Eq, Debug)
struct Person {
  first : String
  last : String
}

///|
/// `first || ' ' || last`, defined once and read two ways.
fn full_name() -> Hybrid[Person] {
  hybrid("full_name", "{t}.first || ' ' || {t}.last", p => {
    @moondb.Text(p.first + " " + p.last)
  })
}

///|
test "a hybrid reads a record through its own projection" {
  let h = full_name()
  assert_eq(h.name(), "full_name")
  assert_eq(
    h.value({ first: "Ada", last: "Lovelace", }),
    @moondb.Text("Ada Lovelace"),
  )
}

///|
test "the table placeholder is substituted everywhere, and only where it appears" {
  let h = full_name()
  assert_eq(h.expr(), "{t}.first || ' ' || {t}.last")
  assert_eq(h.over("people"), "people.first || ' ' || people.last")
  assert_eq(h.sql(), "{t}.first || ' ' || {t}.last")
  assert_eq(h.sql(table="people"), "people.first || ' ' || people.last")
}

///|
test "a hybrid with no placeholder is used as written" {
  let h : Hybrid[Person] = hybrid(
    "initials",
    "substr(first, 1, 1) || substr(last, 1, 1)",
    p => @moondb.Text(substr(p.first) + substr(p.last)),
  )
  assert_eq(h.over("people"), h.expr())
  assert_eq(h.sql(), "substr(first, 1, 1) || substr(last, 1, 1)")
}

///|
fn substr(s : String) -> String {
  if s.length() == 0 {
    ""
  } else {
    s[0].to_string()
  }
}

///|
test "where_hybrid renders the expression as the left-hand side and binds the value" {
  let h = full_name()
  let (sql, params) = select("people")
    .where_hybrid(h, "=", @moondb.Text("Ada Lovelace"))
    .build()
  assert_eq(sql, "SELECT * FROM people WHERE {t}.first || ' ' || {t}.last = ?")
  assert_eq(params, [@moondb.Text("Ada Lovelace")])
  // Qualified, for a query that joins another table with the same column names.
  let (joined, _) = select("people")
    .join("teams", "teams.id = people.team_id")
    .where_hybrid(h, "=", @moondb.Text("Ada Lovelace"), table="people")
    .build()
  assert_eq(
    joined, "SELECT * FROM people JOIN teams ON teams.id = people.team_id WHERE people.first || ' ' || people.last = ?",
  )
}

///|
test "order_hybrid sorts by the computed expression" {
  let h = full_name()
  let (sql, _) = select("people").order_hybrid(h, Desc).build()
  assert_eq(
    sql, "SELECT * FROM people ORDER BY {t}.first || ' ' || {t}.last DESC",
  )
}

///|
test "project_hybrid labels the computed value with the attribute's name" {
  let h = full_name()
  let (sql, _) = select("people").project_hybrid(h, table="people").build()
  assert_eq(
    sql, "SELECT people.first || ' ' || people.last AS full_name FROM people",
  )
}
