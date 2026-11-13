// The schema snapshot: the text a diff between a declared schema and a reflected one
// is read off. Two properties matter — the lines describe the physical structure, and
// they come in an order a reader can follow.

///|
test "snapshot: tables and indexes come in name order, not length order" {
  let schema = Schema::new([
    TableSpec::new("b", [
      column("id", IntType, primary_key=true, nullable=false),
    ]),
    TableSpec::new("ab", [
      column("id", IntType, primary_key=true, nullable=false),
    ]),
    TableSpec::new(
      "account",
      [column("id", IntType, primary_key=true, nullable=false)],
      indexes=[index(["name"], name="ix_b"), index(["email"], name="ix_aa")],
    ),
  ])
  // `ab` and `account` are longer than `b` and still come first: the order is the
  // names', not the lengths'.
  assert_eq(
    schema.snapshot(Sqlite),
    "table ab\n" +
    "  column id INTEGER not null pk\n" +
    "table account\n" +
    "  column id INTEGER not null pk\n" +
    "  index ix_aa (email)\n" +
    "  index ix_b (name)\n" +
    "table b\n" +
    "  column id INTEGER not null pk",
  )
}

///|
test "snapshot: each dialect spells the types it stores" {
  let schema = Schema::new([
    TableSpec::new(
      "account",
      [
        column(
          "id",
          BigIntType,
          primary_key=true,
          autoincrement=true,
          nullable=false,
        ),
        column("email", TextType, nullable=false, unique=true),
        column("score", RealType, nullable=false, default="0"),
      ],
      indexes=[index(["email"], unique=true)],
    ),
  ])
  // The snapshot is what autogenerate compares, so a type has to be written the way
  // the engine under it writes it.
  let sqlite = schema.snapshot(Sqlite)
  assert_true(sqlite.contains("column id INTEGER not null pk auto"))
  assert_true(sqlite.contains("column email TEXT not null"))
  assert_true(sqlite.contains("index uq_account_email unique (email)"))
  assert_true(sqlite.contains("column score REAL not null"))
  assert_true(
    schema.snapshot(Postgres).contains("column id BIGINT not null pk auto"),
  )
  assert_true(
    schema.snapshot(Mysql).contains("column id BIGINT not null pk auto"),
  )
}
