///|
test "ORDER BY places NULLs when asked" {
  let (sql, _) = select("t")
    .order_by("a", Asc, nulls=Last)
    .order_by("b", Desc, nulls=First)
    .order_by("c", Asc)
    .build()
  assert_eq(
    sql, "SELECT * FROM t ORDER BY a ASC NULLS LAST, b DESC NULLS FIRST, c ASC",
  )
}
