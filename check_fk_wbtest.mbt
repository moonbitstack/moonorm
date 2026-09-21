///|
test "Column::ddl emits CHECK constraints" {
  assert_eq(
    column("age", IntType, checks=["age >= 0"]).ddl(),
    "age INTEGER CHECK (age >= 0)",
  )
  assert_eq(
    column("state", TextType, checks=["state IN ('on','off')"]).ddl(),
    "state TEXT CHECK (state IN ('on','off'))",
  )
}

///|
test "Column::ddl emits foreign-key referential actions" {
  assert_eq(
    column(
      "team_id",
      IntType,
      references=("team", "id"),
      on_delete="CASCADE",
      on_update="RESTRICT",
    ).ddl(),
    "team_id INTEGER REFERENCES team(id) ON DELETE CASCADE ON UPDATE RESTRICT",
  )
  // Actions only render when a reference is present.
  assert_eq(column("x", IntType, on_delete="CASCADE").ddl(), "x INTEGER")
}
