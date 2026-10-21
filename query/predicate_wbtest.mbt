///|
test "predicate tree: = NULL folds to IS NULL inside the tree too" {
  let (sql, params) = select("t")
    .where_pred(
      Or([Cmp(col="a", op="=", val=Null), Cmp(col="b", op="=", val=Int(1))]),
    )
    .build()
  assert_eq(sql, "SELECT * FROM t WHERE (a IS NULL OR b = ?)")
  assert_eq(params.length(), 1)
  assert_eq(params[0] == Int(1), true)
  let (ne, np) = select("t")
    .where_pred(And([Cmp(col="a", op="!=", val=Null)]))
    .build()
  assert_eq(ne, "SELECT * FROM t WHERE a IS NOT NULL")
  assert_eq(np.length(), 0)
}
