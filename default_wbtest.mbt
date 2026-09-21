///|
test "Column::ddl emits a DEFAULT expression (server_default)" {
  assert_eq(
    column("status", TextType, nullable=false, default="'active'").ddl(),
    "status TEXT NOT NULL DEFAULT 'active'",
  )
  assert_eq(
    column("count", IntType, default="0").ddl(),
    "count INTEGER DEFAULT 0",
  )
  // No default -> no clause.
  assert_eq(column("x", TextType).ddl(), "x TEXT")
}
