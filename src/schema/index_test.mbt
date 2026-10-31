///|
test "indexes render per dialect, named after the table when not named" {
  let model : @schema.Model[Int32] = @schema.Model::new(
    "heroes",
    [@schema.column("name", TextType), @schema.column("age", IntType)],
    r => r.int(0),
    _ => [],
    indexes=[
      @schema.index(["name"]),
      @schema.index(["name", "age"], unique=true),
      @schema.index(["age"], name="by_age"),
    ],
  )
  assert_eq(model.create_indexes_sql(), [
    "CREATE INDEX ix_heroes_name ON heroes (name)", "CREATE UNIQUE INDEX uq_heroes_name_age ON heroes (name, age)",
    "CREATE INDEX by_age ON heroes (age)",
  ])
  assert_eq(
    model.create_indexes_sql_for(Postgres, if_not_exists=true)[0],
    "CREATE INDEX IF NOT EXISTS ix_heroes_name ON heroes (name)",
  )
  assert_eq(
    model.create_indexes_sql_for(Mysql, if_not_exists=true)[0],
    "CREATE INDEX ix_heroes_name ON heroes (name)",
  )
}
