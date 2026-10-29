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

///|
priv struct Acct {
  id : Int64?
  email : String
  balance : Double
  team_id : Int64
  status : String
  level : Int32
}

///|
test "multi-dialect CREATE TABLE carries foreign key, check, unique and default" {
  let m : Model[Acct] = Model::new(
    "accounts",
    [
      column("id", BigIntType, primary_key=true, autoincrement=true),
      column("email", TextType, nullable=false, unique=true),
      column("balance", RealType),
      column(
        "team_id",
        BigIntType,
        references=("teams", "id"),
        on_delete="SET NULL",
      ),
      column("status", TextType, nullable=false, default="'active'"),
      column("level", IntType, checks=["level >= 0"]),
    ],
    r => {
      id: r.read(0),
      email: r.read(1),
      balance: r.read(2),
      team_id: r.read(3),
      status: r.read(4),
      level: r.read(5),
    },
    x => {
      [
        (
          "id",
          match x.id {
            Some(v) => @moondb.Int64(v)
            None => @moondb.Null
          },
        ),
        ("email", @moondb.Text(x.email)),
        ("balance", @moondb.Double(x.balance)),
        ("team_id", @moondb.Int64(x.team_id)),
        ("status", @moondb.Text(x.status)),
        ("level", @moondb.Int(x.level)),
      ]
    },
  )
  assert_eq(
    m.create_table_sql_for(Postgres),
    "CREATE TABLE accounts (id BIGSERIAL PRIMARY KEY, email TEXT NOT NULL UNIQUE, balance DOUBLE PRECISION, team_id BIGINT REFERENCES teams(id) ON DELETE SET NULL, status TEXT NOT NULL DEFAULT 'active', level INTEGER CHECK (level >= 0))",
  )
  assert_eq(
    m.create_table_sql_for(Mysql),
    "CREATE TABLE accounts (id BIGINT AUTO_INCREMENT PRIMARY KEY, email TEXT NOT NULL UNIQUE, balance DOUBLE, team_id BIGINT REFERENCES teams(id) ON DELETE SET NULL, status TEXT NOT NULL DEFAULT 'active', level INT CHECK (level >= 0)) ENGINE=InnoDB",
  )
  assert_eq(
    m.create_table_sql_for(Sqlite),
    "CREATE TABLE accounts (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT NOT NULL UNIQUE, balance REAL, team_id INTEGER REFERENCES teams(id) ON DELETE SET NULL, status TEXT NOT NULL DEFAULT 'active', level INTEGER CHECK (level >= 0))",
  )
}

///|
test "create_table_sql_for honours if_not_exists on every dialect" {
  let m : Model[Acct] = Model::new(
    "accounts",
    [
      column("id", BigIntType, primary_key=true, autoincrement=true),
      column("email", TextType, nullable=false, unique=true),
      column("balance", RealType),
      column(
        "team_id",
        BigIntType,
        references=("teams", "id"),
        on_delete="SET NULL",
      ),
      column("status", TextType, nullable=false, default="'active'"),
      column("level", IntType, checks=["level >= 0"]),
    ],
    r => {
      id: r.read(0),
      email: r.read(1),
      balance: r.read(2),
      team_id: r.read(3),
      status: r.read(4),
      level: r.read(5),
    },
    x => {
      [
        (
          "id",
          match x.id {
            Some(v) => @moondb.Int64(v)
            None => @moondb.Null
          },
        ),
        ("email", @moondb.Text(x.email)),
        ("balance", @moondb.Double(x.balance)),
        ("team_id", @moondb.Int64(x.team_id)),
        ("status", @moondb.Text(x.status)),
        ("level", @moondb.Int(x.level)),
      ]
    },
  )
  assert_eq(
    m.create_table_sql_for(Postgres, if_not_exists=true),
    "CREATE TABLE IF NOT EXISTS accounts (id BIGSERIAL PRIMARY KEY, email TEXT NOT NULL UNIQUE, balance DOUBLE PRECISION, team_id BIGINT REFERENCES teams(id) ON DELETE SET NULL, status TEXT NOT NULL DEFAULT 'active', level INTEGER CHECK (level >= 0))",
  )
  assert_eq(
    m.create_table_sql_for(Mysql, if_not_exists=true),
    "CREATE TABLE IF NOT EXISTS accounts (id BIGINT AUTO_INCREMENT PRIMARY KEY, email TEXT NOT NULL UNIQUE, balance DOUBLE, team_id BIGINT REFERENCES teams(id) ON DELETE SET NULL, status TEXT NOT NULL DEFAULT 'active', level INT CHECK (level >= 0)) ENGINE=InnoDB",
  )
  assert_eq(
    m.create_table_sql_for(Sqlite, if_not_exists=true),
    "CREATE TABLE IF NOT EXISTS accounts (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT NOT NULL UNIQUE, balance REAL, team_id INTEGER REFERENCES teams(id) ON DELETE SET NULL, status TEXT NOT NULL DEFAULT 'active', level INTEGER CHECK (level >= 0))",
  )
}
