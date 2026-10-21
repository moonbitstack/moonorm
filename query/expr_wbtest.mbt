///|
test "expression helpers: func, cast, case_, label" {
  let (sql, _) = select("t")
    .label(func("coalesce", ["a", "b"]), "ab")
    .raw(cast("price", "NUMERIC(10,2)"))
    .raw(case_([("x > 0", "'pos'")], else_="'neg'"))
    .build()
  assert_eq(
    sql, "SELECT coalesce(a, b) AS ab, CAST(price AS NUMERIC(10,2)), CASE WHEN x > 0 THEN 'pos' ELSE 'neg' END FROM t",
  )
  assert_eq(
    case_([("a", "1"), ("b", "2")]),
    "CASE WHEN a THEN 1 WHEN b THEN 2 END",
  )
  assert_eq(case_([]), "NULL")
  assert_eq(case_([], else_="0"), "0")
}
