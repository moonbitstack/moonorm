///|
test "delete" {
  let (sql, params) = delete("users").where_("id", "=", Int(9)).build()
  assert_eq(sql, "DELETE FROM users WHERE id = ?")
  assert_eq(params.length(), 1)
}

///|
test "delete: predicate tree, subquery, RETURNING" {
  let (p, pp) = delete("t")
    .where_pred(Not(Cmp(col="a", op="=", val=Int(1))))
    .returning_all()
    .build()
  assert_eq(p, "DELETE FROM t WHERE NOT (a = ?) RETURNING *")
  assert_eq(pp.length(), 1)
  assert_eq(pp[0] == Int(1), true)
  let (s, sp) = delete("t")
    .where_("k", "=", Text("hhh"))
    .where_in("id", select("s").column("id").where_("y", "<", Int(4)))
    .build()
  assert_eq(
    s, "DELETE FROM t WHERE k = ? AND id IN (SELECT id FROM s WHERE y < ?)",
  )
  assert_eq(sp.length(), 2)
  assert_eq(sp[0] == Text("hhh"), true)
  assert_eq(sp[1] == Int(4), true)
  let (n, _) = delete("t").where_not_in("id", select("s").column("id")).build()
  assert_eq(n, "DELETE FROM t WHERE id NOT IN (SELECT id FROM s)")
  let (my, _) = delete("t")
    .where_("id", "=", Int(1))
    .returning("id")
    .build_for(Mysql)
  assert_eq(my, "DELETE FROM t WHERE id = ?")
}

///|
test "a Delete is a safe base to branch from" {
  let base = delete("t")
  assert_eq(
    base.where_("id", "=", Int(1)).build().0,
    "DELETE FROM t WHERE id = ?",
  )
  assert_eq(
    base.where_pred(Cmp(col="k", op="=", val=Int(3))).build().0,
    "DELETE FROM t WHERE k = ?",
  )
  assert_eq(
    base.where_in("id", select("s").column("id")).build().0,
    "DELETE FROM t WHERE id IN (SELECT id FROM s)",
  )
  assert_eq(base.returning("id").build().0, "DELETE FROM t RETURNING id")
  assert_eq(base.build().0, "DELETE FROM t")
}
