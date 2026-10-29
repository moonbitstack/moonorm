///|
test "autoincrement primary key renders AUTOINCREMENT" {
  assert_eq(
    column("id", IntType, primary_key=true, autoincrement=true).ddl(),
    "id INTEGER PRIMARY KEY AUTOINCREMENT",
  )
  // Not emitted without a primary key.
  assert_eq(column("n", IntType, autoincrement=true).ddl(), "n INTEGER")
}

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

///|
test "Column::ddl emits UNIQUE for a unique non-key column" {
  assert_eq(
    column("email", TextType, nullable=false, unique=true).ddl(),
    "email TEXT NOT NULL UNIQUE",
  )
  // A primary key is already unique, so UNIQUE is not re-emitted.
  assert_eq(
    column("id", IntType, primary_key=true, unique=true).ddl(),
    "id INTEGER PRIMARY KEY",
  )
  // Plain nullable unique column.
  assert_eq(column("slug", TextType, unique=true).ddl(), "slug TEXT UNIQUE")
}

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

///|
test "extended column types render their declared SQL type" {
  assert_eq(column("name", VarcharType(255)).ddl(), "name VARCHAR(255)")
  assert_eq(column("price", NumericType).ddl(), "price NUMERIC")
  assert_eq(column("created", DateTimeType).ddl(), "created DATETIME")
  assert_eq(column("d", DateType).ddl(), "d DATE")
  assert_eq(column("t", TimeType).ddl(), "t TIME")
  // UUID / JSON store as TEXT on SQLite.
  assert_eq(column("uid", UuidType).ddl(), "uid TEXT")
  assert_eq(column("doc", JsonType).ddl(), "doc TEXT")
}

///|
test "BigIntType renders BIGINT except on SQLite" {
  assert_eq(BigIntType.sql_for(Postgres), "BIGINT")
  assert_eq(BigIntType.sql_for(Mysql), "BIGINT")
  assert_eq(BigIntType.sql_for(Sqlite), "INTEGER")
  assert_eq(IntType.sql_for(Postgres), "INTEGER")
  assert_eq(column("n", BigIntType).ddl(), "n INTEGER")
  assert_eq(column("n", BigIntType).ddl_for(Postgres), "n BIGINT")
}

///|
test "BigIntType autoincrement takes each engine's 64-bit idiom" {
  let id = column("id", BigIntType, primary_key=true, autoincrement=true)
  assert_eq(id.ddl_for(Postgres), "id BIGSERIAL PRIMARY KEY")
  assert_eq(id.ddl_for(Mysql), "id BIGINT AUTO_INCREMENT PRIMARY KEY")
  assert_eq(id.ddl_for(Sqlite), "id INTEGER PRIMARY KEY AUTOINCREMENT")
  let small = column("id", IntType, primary_key=true, autoincrement=true)
  assert_eq(small.ddl_for(Postgres), "id SERIAL PRIMARY KEY")
  assert_eq(small.ddl_for(Mysql), "id INT AUTO_INCREMENT PRIMARY KEY")
}
