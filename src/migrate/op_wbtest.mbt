///|
/// The three columns the operation tests build on: an integer key and two text
/// columns, so a rendered `CREATE TABLE` reads like the one a migration writes.
fn op_columns() -> Array[@schema.Column] {
  [
    @schema.column("id", IntType, primary_key=true, autoincrement=true),
    @schema.column("name", TextType, nullable=false),
    @schema.column("email", TextType, unique=true),
  ]
}

///|
test "create_table renders per dialect, with each engine's autoincrement idiom" {
  let op = create_table("users", op_columns())
  let sqlite = op.to_sql(Sqlite)
  assert_eq(sqlite.length(), 1)
  assert_eq(
    sqlite[0],
    "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, email TEXT UNIQUE)",
  )
  let pg = op.to_sql(Postgres)
  assert_eq(
    pg[0],
    "CREATE TABLE users (id SERIAL PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE)",
  )
  let my = op.to_sql(Mysql)
  assert_eq(
    my[0],
    "CREATE TABLE users (id INT AUTO_INCREMENT PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE) ENGINE=InnoDB",
  )
}

///|
test "drop_table and the if_exists forms" {
  assert_eq(drop_table("users").to_sql(Sqlite), ["DROP TABLE users"])
  assert_eq(drop_table("users", if_exists=true).to_sql(Postgres), [
    "DROP TABLE IF EXISTS users",
  ])
}

///|
test "add and drop a column" {
  let add = add_column("users", @schema.column("age", IntType))
  assert_eq(add.to_sql(Postgres), ["ALTER TABLE users ADD COLUMN age INTEGER"])
  assert_eq(drop_column("users", "age").to_sql(Mysql), [
    "ALTER TABLE users DROP COLUMN age",
  ])
}

///|
test "rename_table and rename_column are one statement on every dialect" {
  assert_eq(rename_table("hero", "heroes").to_sql(Sqlite), [
    "ALTER TABLE hero RENAME TO heroes",
  ])
  assert_eq(rename_column("heroes", "power", "strength").to_sql(Mysql), [
    "ALTER TABLE heroes RENAME COLUMN power TO strength",
  ])
}

///|
test "alter_column on PostgreSQL is one statement per changed property" {
  let type_only = alter_column("heroes", "power", col_type=BigIntType)
  assert_eq(type_only.to_sql(Postgres), [
    "ALTER TABLE heroes ALTER COLUMN power TYPE BIGINT",
  ])
  let both = alter_column("heroes", "power", nullable=false, default="0")
  assert_eq(both.to_sql(Postgres), [
    "ALTER TABLE heroes ALTER COLUMN power SET NOT NULL", "ALTER TABLE heroes ALTER COLUMN power SET DEFAULT 0",
  ])
  let renamed = alter_column("heroes", "power", new_name="strength")
  assert_eq(renamed.to_sql(Postgres), [
    "ALTER TABLE heroes RENAME COLUMN power TO strength",
  ])
  let dropped = alter_column("heroes", "power", drop_default=true)
  assert_eq(dropped.to_sql(Postgres), [
    "ALTER TABLE heroes ALTER COLUMN power DROP DEFAULT",
  ])
}

///|
test "alter_column on MySQL restates the column and refuses a guess" {
  let full = alter_column(
    "heroes",
    "power",
    col_type=IntType,
    nullable=false,
    default="1",
  )
  assert_eq(full.to_sql(Mysql), [
    "ALTER TABLE heroes MODIFY COLUMN power INT NOT NULL DEFAULT 1",
  ])
  let guessed = try {
    alter_column("heroes", "power", nullable=false).to_sql(Mysql) |> ignore
    false
  } catch {
    @moondb.QueryError(_) => true
    _ => false
  }
  assert_eq(guessed, true)
}

///|
test "alter_column on SQLite renames, and refuses anything else" {
  let renamed = alter_column("heroes", "power", new_name="strength")
  assert_eq(renamed.to_sql(Sqlite), [
    "ALTER TABLE heroes RENAME COLUMN power TO strength",
  ])
  let refused = try {
    alter_column("heroes", "power", col_type=BigIntType).to_sql(Sqlite)
    |> ignore
    false
  } catch {
    @moondb.QueryError(message) => message.contains("rebuild_table")
    _ => false
  }
  assert_eq(refused, true)
}

///|
test "foreign keys: added on PostgreSQL and MySQL, refused on SQLite" {
  let fk = add_foreign_key(
    "heroes",
    "fk_heroes_team",
    ["team_id"],
    "teams",
    ["id"],
    on_delete="CASCADE",
  )
  assert_eq(fk.to_sql(Postgres), [
    "ALTER TABLE heroes ADD CONSTRAINT fk_heroes_team FOREIGN KEY (team_id) REFERENCES teams (id) ON DELETE CASCADE",
  ])
  assert_eq(fk.to_sql(Mysql), [
    "ALTER TABLE heroes ADD CONSTRAINT fk_heroes_team FOREIGN KEY (team_id) REFERENCES teams (id) ON DELETE CASCADE",
  ])
  let refused = try {
    fk.to_sql(Sqlite) |> ignore
    false
  } catch {
    @moondb.QueryError(_) => true
    _ => false
  }
  assert_eq(refused, true)
  assert_eq(drop_foreign_key("heroes", "fk_heroes_team").to_sql(Postgres), [
    "ALTER TABLE heroes DROP CONSTRAINT fk_heroes_team",
  ])
  assert_eq(drop_foreign_key("heroes", "fk_heroes_team").to_sql(Mysql), [
    "ALTER TABLE heroes DROP FOREIGN KEY fk_heroes_team",
  ])
}

///|
test "indexes: created with IF NOT EXISTS where the engine takes it, dropped per engine" {
  let ix = create_index(
    "ix_heroes_name",
    "heroes",
    ["name"],
    if_not_exists=true,
  )
  assert_eq(ix.to_sql(Postgres), [
    "CREATE INDEX IF NOT EXISTS ix_heroes_name ON heroes (name)",
  ])
  assert_eq(ix.to_sql(Mysql), ["CREATE INDEX ix_heroes_name ON heroes (name)"])
  assert_eq(drop_index("ix_heroes_name").to_sql(Sqlite), [
    "DROP INDEX ix_heroes_name",
  ])
  assert_eq(drop_index("ix_heroes_name", table="heroes").to_sql(Mysql), [
    "DROP INDEX ix_heroes_name ON heroes",
  ])
}

///|
test "rebuild_table is the four-step swap SQLite needs, and is refused elsewhere" {
  let cols = [
    @schema.column("id", IntType, primary_key=true),
    @schema.column("name", TextType, nullable=false),
  ]
  let op = rebuild_table("heroes", cols, ["id"])
  assert_eq(op.to_sql(Sqlite), [
    "CREATE TABLE moonorm_batch_heroes (id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
    "INSERT INTO moonorm_batch_heroes (id) SELECT id FROM heroes", "DROP TABLE heroes",
    "ALTER TABLE moonorm_batch_heroes RENAME TO heroes",
  ])
  let refused = try {
    op.to_sql(Postgres) |> ignore
    false
  } catch {
    @moondb.QueryError(_) => true
    _ => false
  }
  assert_eq(refused, true)
}

///|
test "rebuild_table without a copy list still swaps the empty table in" {
  let cols = [@schema.column("id", IntType, primary_key=true)]
  let sql = rebuild_table("heap", cols, []).to_sql(Sqlite)
  assert_eq(sql.length(), 3)
  assert_eq(sql[1], "DROP TABLE heap")
}

///|
test "execute passes its SQL through untouched" {
  assert_eq(execute("UPDATE heroes SET power = power + 1").to_sql(Sqlite), [
    "UPDATE heroes SET power = power + 1",
  ])
}
