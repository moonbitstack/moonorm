///|
test "where_pred: OR grouping stays parameterized" {
  let (sql, params) = select("users")
    .column("id")
    .where_pred(
      Or([
        Cmp(col="name", op="=", val=Text("a")),
        Cmp(col="name", op="=", val=Text("b")),
      ]),
    )
    .build()
  assert_eq(sql, "SELECT id FROM users WHERE (name = ? OR name = ?)")
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Text("a"), true)
  assert_eq(params[1] == Text("b"), true)
}

///|
test "where_pred: nested AND/OR/NOT and mixing with eq" {
  let (sql, params) = select("t")
    .eq("active", Bool(true))
    .where_pred(
      And([
        Or([Cmp(col="a", op=">", val=Int(1)), Cmp(col="b", op="<", val=Int(9))]),
        Not(Cmp(col="c", op="=", val=Int(0))),
      ]),
    )
    .build()
  assert_eq(
    sql, "SELECT * FROM t WHERE active = ? AND ((a > ? OR b < ?) AND NOT (c = ?))",
  )
  assert_eq(params.length(), 4)
  assert_eq(params[0] == Bool(true), true)
  assert_eq(params[3] == Int(0), true)
}

///|
test "where_pred: IN list inside a predicate tree" {
  let (sql, _) = select("t")
    .where_pred(InList(col="id", vals=[Int(1), Int(2), Int(3)], negated=false))
    .build()
  assert_eq(sql, "SELECT * FROM t WHERE id IN (?, ?, ?)")
}

///|
test "where_in_values: renders placeholders and binds each value in text order" {
  let (sql, params) = select("books")
    .column("id")
    .where_("shelf", "=", Text("scifi"))
    .where_in_values("author_id", [Int(1), Int(2), Int(3)])
    .build()
  assert_eq(
    sql, "SELECT id FROM books WHERE shelf = ? AND author_id IN (?, ?, ?)",
  )
  // Scalar predicate first, then each IN value — the SQL text order.
  assert_eq(params.length(), 4)
  assert_eq(params[0] == Text("scifi"), true)
  assert_eq(params[1] == Int(1), true)
  assert_eq(params[3] == Int(3), true)
}

///|
test "where_not_in_values and the empty set" {
  let (sql1, p1) = select("t").where_not_in_values("k", [Int(9)]).build()
  assert_eq(sql1, "SELECT * FROM t WHERE k NOT IN (?)")
  assert_eq(p1[0] == Int(9), true)
  // The empty set constant-folds: empty IN matches nothing (1 = 0), empty NOT IN
  // matches everything (1 = 1) — never `IN (NULL)`, which is wrong under NULL logic.
  let (sql2, p2) = select("t").where_in_values("k", []).build()
  assert_eq(sql2, "SELECT * FROM t WHERE 1 = 0")
  assert_eq(p2.length(), 0)
  let (sql3, p3) = select("t").where_not_in_values("k", []).build()
  assert_eq(sql3, "SELECT * FROM t WHERE 1 = 1")
  assert_eq(p3.length(), 0)
}

///|
test "where_in_values sits between scalar and subquery predicates in param order" {
  let sub = select("banned").column("id").where_("active", "=", Bool(true))
  let (sql, params) = select("t")
    .where_("a", "=", Int(1))
    .where_in_values("b", [Int(2), Int(3)])
    .where_in("c", sub)
    .build()
  assert_eq(
    sql, "SELECT * FROM t WHERE a = ? AND b IN (?, ?) AND c IN (SELECT id FROM banned WHERE active = ?)",
  )
  // scalar(1) -> in-values(2,3) -> subquery(true): exactly the text order.
  assert_eq(params.length(), 4)
  assert_eq(params[0] == Int(1), true)
  assert_eq(params[1] == Int(2), true)
  assert_eq(params[2] == Int(3), true)
  assert_eq(params[3] == Bool(true), true)
}

// --- N+1-avoiding batch load ----------------------------------------------------
