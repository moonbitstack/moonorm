///|
priv struct MU {
  id : Int32
}

///|
test "multi-dialect CREATE TABLE renders per-engine types and autoincrement" {
  let m : Model[MU] = Model::new(
    "u",
    [
      column("id", IntType, primary_key=true, autoincrement=true),
      column("active", BoolType),
      column("name", VarcharType(100)),
      column("doc", JsonType),
    ],
    r => { id: r.int(0), },
    x => [("id", @moondb.Int(x.id))],
  )
  assert_eq(
    m.create_table_sql_for(Postgres),
    "CREATE TABLE u (id SERIAL PRIMARY KEY, active BOOLEAN, name VARCHAR(100), doc JSONB)",
  )
  assert_eq(
    m.create_table_sql_for(Mysql),
    "CREATE TABLE u (id INT AUTO_INCREMENT PRIMARY KEY, active TINYINT(1), name VARCHAR(100), doc JSON) ENGINE=InnoDB",
  )
  assert_eq(
    m.create_table_sql_for(Sqlite),
    "CREATE TABLE u (id INTEGER PRIMARY KEY AUTOINCREMENT, active INTEGER, name VARCHAR(100), doc TEXT)",
  )
}
