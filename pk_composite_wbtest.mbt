///|
priv struct MLink {
  a : Int32
  b : Int32
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
