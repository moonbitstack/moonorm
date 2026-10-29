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

///|
priv struct Auto {
  id : Int64?
  name : String
  note : String?
}

///|
fn auto_model() -> Model[Auto] {
  Model::from_fields(
    "auto",
    [
      field("id", BigIntType, a => a.id, primary_key=true, autoincrement=true),
      field("name", TextType, a => a.name, nullable=false),
      field("note", TextType, a => a.note),
    ],
    r => { id: r.read(0), name: r.read(1), note: r.read(2), },
  )
}

///|
test "from_fields leaves out an autoincrement key that is still NULL" {
  let m = auto_model()
  let fresh : Auto = { id: None, name: "a", note: None, }
  assert_eq((m.to_columns)(fresh), [
    ("name", @moondb.Text("a")),
    ("note", @moondb.Null),
  ])
  assert_eq(m.pk_of(fresh).length(), 0)
  let known = { ..fresh, id: Some(9L), }
  assert_eq((m.to_columns)(known), [
    ("id", @moondb.Int64(9)),
    ("name", @moondb.Text("a")),
    ("note", @moondb.Null),
  ])
  assert_eq(m.pk_of(known), [@moondb.Int64(9)])
}

///|
test "field binds the attribute itself, an option, or a Value" {
  let direct : Field[Auto] = field("name", TextType, a => a.name)
  let raw : Field[Auto] = field("name", TextType, a => @moondb.Text(a.name))
  let r : Auto = { id: None, name: "x", note: Some("n"), }
  assert_eq((direct.encode)(r), (raw.encode)(r))
  let note : Field[Auto] = field("note", TextType, a => a.note)
  assert_eq((note.encode)(r), @moondb.Text("n"))
  assert_eq((note.encode)({ ..r, note: None, }), @moondb.Null)
}

///|
test "from_row reads each cell as the field's type" {
  let m = auto_model()
  let row : @moondb.Row = {
    columns: ["id", "name", "note"],
    values: [Int64(3), Text("b"), Null],
  }
  let a = m.map_row(row)
  assert_eq((a.id, a.name, a.note), (Some(3L), "b", None))
}
