// Adversarial checks for the query builder: the guarantee is that every value is a
// bound parameter and never part of the SQL text, so injection, quotes and reserved
// words in *data* cannot change a statement; identifiers are trusted and pass through
// verbatim; and an empty IN folds to a constant instead of the invalid `IN ()`.

///|
test "adversarial: a value is a bound parameter in every statement kind" {
  let evil = "'; DROP TABLE users; --"
  let (s_sql, s_params) = select("users").eq("name", Text(evil)).build()
  assert_eq(s_sql, "SELECT * FROM users WHERE name = ?")
  assert_eq(s_params.length(), 1)
  assert_eq(s_params[0] == Text(evil), true)

  let (i_sql, i_params) = insert("users").set("name", Text(evil)).build()
  assert_eq(i_sql, "INSERT INTO users (name) VALUES (?)")
  assert_eq(i_params[0] == Text(evil), true)

  let (u_sql, u_params) = update("users")
    .set("name", Text(evil))
    .where_("id", "=", Int(1))
    .build()
  assert_eq(u_sql, "UPDATE users SET name = ? WHERE id = ?")
  assert_eq(u_params.length(), 2)
  assert_eq(u_params[0] == Text(evil), true)

  let (d_sql, d_params) = delete("users")
    .where_("name", "=", Text(evil))
    .build()
  assert_eq(d_sql, "DELETE FROM users WHERE name = ?")
  assert_eq(d_params[0] == Text(evil), true)
}

///|
test "adversarial: quotes and backslashes in a value stay data" {
  let samples : Array[String] = [
    "O'Brien",
    "a\"b",
    "back\\slash",
    "semi;colon",
    "line\nbreak",
  ]
  for s in samples {
    let (sql, params) = select("t").eq("c", Text(s)).build()
    assert_eq(sql, "SELECT * FROM t WHERE c = ?")
    assert_eq(params[0] == Text(s), true)
  }
}

///|
test "adversarial: identifiers are trusted and pass through verbatim" {
  // The builder never quotes identifiers, so a caller supplies valid ones; a
  // reserved word reaches the SQL unchanged, while the value stays bound.
  let (sql, params) = select("orders")
    .column("order")
    .eq("group", Text("x"))
    .build()
  assert_eq(sql, "SELECT order FROM orders WHERE group = ?")
  assert_eq(params[0] == Text("x"), true)
}

///|
test "adversarial: an evil LIKE pattern is one bound parameter" {
  let pattern = "%' OR '1'='1"
  let (sql, params) = select("users")
    .where_("name", "LIKE", Text(pattern))
    .build()
  assert_eq(sql, "SELECT * FROM users WHERE name LIKE ?")
  assert_eq(params[0] == Text(pattern), true)
}

///|
test "adversarial: a multi-row insert binds every value" {
  let (sql, params) = insert("t")
    .set("a", Text("x'"))
    .values([Text("y; DROP TABLE t")])
    .build()
  assert_eq(sql, "INSERT INTO t (a) VALUES (?), (?)")
  assert_eq(params.length(), 2)
  assert_eq(params[1] == Text("y; DROP TABLE t"), true)
}

///|
test "adversarial: an empty IN is a constant, never IN ()" {
  let (s_sql, s_params) = select("t").where_in_values("k", []).build()
  assert_eq(s_sql, "SELECT * FROM t WHERE 1 = 0")
  assert_eq(s_params.length(), 0)

  let (u_sql, u_params) = update("t")
    .set("v", Int(1))
    .where_pred(InList(col="k", vals=[], negated=false))
    .build()
  assert_eq(u_sql, "UPDATE t SET v = ? WHERE 1 = 0")
  assert_eq(u_params.length(), 1)

  let (d_sql, _) = delete("t")
    .where_pred(InList(col="k", vals=[], negated=false))
    .build()
  assert_eq(d_sql, "DELETE FROM t WHERE 1 = 0")

  // NOT IN over the empty set matches everything.
  let (n_sql, n_params) = select("t").where_not_in_values("k", []).build()
  assert_eq(n_sql, "SELECT * FROM t WHERE 1 = 1")
  assert_eq(n_params.length(), 0)
}
