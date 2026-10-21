///|
test "update" {
  let (sql, params) = update("users")
    .set("age", Int(31))
    .where_("id", "=", Int(1))
    .build()
  assert_eq(sql, "UPDATE users SET age = ? WHERE id = ?")
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Int(31), true)
  assert_eq(params[1] == Int(1), true)
}

///|
test "update: a column can be set to an expression over itself" {
  let (sql, params) = update("counters")
    .set_expr("n", "n + ?", vals=[Int(1)])
    .where_("id", "=", Int(7))
    .build()
  assert_eq(sql, "UPDATE counters SET n = n + ? WHERE id = ?")
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Int(1), true)
  assert_eq(params[1] == Int(7), true)
}

///|
test "update: bound and expression assignments mix, in call order" {
  let (sql, params) = update("t")
    .set("a", Text("qwq"))
    .set_expr("n", "n + 1")
    .set("b", Int(233))
    .build()
  assert_eq(sql, "UPDATE t SET a = ?, n = n + 1, b = ?")
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Text("qwq"), true)
  assert_eq(params[1] == Int(233), true)
}

///|
test "update: a predicate tree narrows it like a query" {
  let (sql, params) = update("t")
    .set("a", Int(1))
    .where_pred(
      Or([Cmp(col="b", op="=", val=Int(2)), Cmp(col="c", op="=", val=Int(3))]),
    )
    .build()
  assert_eq(sql, "UPDATE t SET a = ? WHERE (b = ? OR c = ?)")
  assert_eq(params.length(), 3)
  assert_eq(params[0] == Int(1), true)
  assert_eq(params[1] == Int(2), true)
  assert_eq(params[2] == Int(3), true)
}

///|
test "update: IN (subquery), with SET / WHERE / subquery values in text order" {
  let (sql, params) = update("t")
    .set("flag", Bool(true))
    .where_("k", "=", Int(9))
    .where_in("id", select("s").column("id").where_("x", ">", Int(5)))
    .build()
  assert_eq(
    sql, "UPDATE t SET flag = ? WHERE k = ? AND id IN (SELECT id FROM s WHERE x > ?)",
  )
  assert_eq(params.length(), 3)
  assert_eq(params[0] == Bool(true), true)
  assert_eq(params[1] == Int(9), true)
  assert_eq(params[2] == Int(5), true)
}

///|
test "update: NOT IN (subquery)" {
  let (sql, _) = update("t")
    .set("a", Int(1))
    .where_not_in("id", select("s").column("id"))
    .build()
  assert_eq(sql, "UPDATE t SET a = ? WHERE id NOT IN (SELECT id FROM s)")
}

///|
test "update RETURNING: sqlite/pg emit it, MySQL drops it" {
  let stmt = update("t").set("a", Int(1)).where_("id", "=", Int(2))
  let (sql, params) = stmt.returning("id").returning("a").build()
  assert_eq(sql, "UPDATE t SET a = ? WHERE id = ? RETURNING id, a")
  assert_eq(params.length(), 2)
  let (my, _) = stmt.returning("id").build_for(Mysql)
  assert_eq(my, "UPDATE t SET a = ? WHERE id = ?")
  let (star, _) = stmt.returning_all().build()
  assert_eq(star, "UPDATE t SET a = ? WHERE id = ? RETURNING *")
}

///|
test "an Update is a safe base to branch from" {
  let base = update("t").set("a", Int(1))
  let (u1, p1) = base.where_("id", "=", Int(1)).build()
  let (u2, p2) = base.where_("id", "=", Int(2)).build()
  assert_eq(u1, "UPDATE t SET a = ? WHERE id = ?")
  assert_eq(u2, "UPDATE t SET a = ? WHERE id = ?")
  assert_eq(p1[1] == Int(1), true)
  assert_eq(p2[1] == Int(2), true)
  assert_eq(base.set("b", Int(2)).build().0, "UPDATE t SET a = ?, b = ?")
  assert_eq(
    base.set_expr("n", "n + 1").build().0,
    "UPDATE t SET a = ?, n = n + 1",
  )
  assert_eq(
    base.where_pred(Cmp(col="k", op="=", val=Int(3))).build().0,
    "UPDATE t SET a = ? WHERE k = ?",
  )
  assert_eq(
    base.where_in("id", select("s").column("id")).build().0,
    "UPDATE t SET a = ? WHERE id IN (SELECT id FROM s)",
  )
  assert_eq(base.returning("id").build().0, "UPDATE t SET a = ? RETURNING id")
  assert_eq(base.build().0, "UPDATE t SET a = ?")
}
