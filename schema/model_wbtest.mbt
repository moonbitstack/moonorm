///|
priv struct MLink {
  a : Int32
  b : Int32
}

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

///|
test "composite primary key becomes a table-level constraint" {
  let m = Model::new(
    "link",
    [
      column("a", IntType, primary_key=true),
      column("b", IntType, primary_key=true),
      column("note", TextType),
    ],
    r => { a: r.int(0), b: r.int(1), },
    x => [("a", @moondb.Int(x.a)), ("b", @moondb.Int(x.b))],
  )
  assert_eq(
    m.create_table_sql(),
    "CREATE TABLE link (a INTEGER NOT NULL, b INTEGER NOT NULL, note TEXT, PRIMARY KEY (a, b))",
  )
}

///|
test "a single primary key stays inline" {
  let m = Model::new(
    "one",
    [column("id", IntType, primary_key=true), column("v", TextType)],
    r => { a: r.int(0), b: 0, },
    _ => [],
  )
  assert_eq(
    m.create_table_sql(),
    "CREATE TABLE one (id INTEGER PRIMARY KEY, v TEXT)",
  )
}
