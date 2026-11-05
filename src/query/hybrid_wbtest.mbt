///|
/// A record with the two columns a name is built from, so the hybrid can be read both
/// ways without a database.
priv struct Person {
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
test "where_hybrid qualifies with the query's own table and binds the value" {
  let h = full_name()
  let (sql, params) = select("people")
    .where_hybrid(h, "=", @moondb.Text("Ada Lovelace"))
    .build()
  assert_eq(
    sql, "SELECT * FROM people WHERE people.first || ' ' || people.last = ?",
  )
  assert_eq(params, [@moondb.Text("Ada Lovelace")])
  // A joined query is the same statement: the qualifier is already explicit.
  let (joined, _) = select("people")
    .join("teams", "teams.id = people.team_id")
    .where_hybrid(h, "=", @moondb.Text("Ada Lovelace"))
    .build()
  assert_eq(
    joined, "SELECT * FROM people JOIN teams ON teams.id = people.team_id WHERE people.first || ' ' || people.last = ?",
  )
}

///|
test "where_hybrid refuses a query with no table to qualify by" {
  let h = full_name()
  let refused = try {
    select(Sub(select("people")))
    .where_hybrid(h, "=", @moondb.Text("Ada Lovelace"))
    .build()
    |> ignore
    false
  } catch {
    @moondb.QueryError(message) => message.contains("name a table")
    _ => false
  }
  assert_eq(refused, true)
}

///|
test "order_hybrid sorts by the computed expression" {
  let h = full_name()
  let (sql, _) = select("people").order_hybrid(h, Desc).build()
  assert_eq(
    sql, "SELECT * FROM people ORDER BY people.first || ' ' || people.last DESC",
  )
}

///|
test "project_hybrid labels the computed value with the attribute's name" {
  let h = full_name()
  let (sql, _) = select("people").project_hybrid(h).build()
  assert_eq(
    sql, "SELECT people.first || ' ' || people.last AS full_name FROM people",
  )
}
