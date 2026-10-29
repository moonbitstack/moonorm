///|
/// Code without spaces, line breaks or the trailing commas the printer adds when
/// it wraps a call, so a test can look for one call written on one line.
fn flat(code : String) -> String {
  let out = StringBuilder()
  for c in code {
    if c != ' ' && c != '\n' {
      out.write_char(c)
    }
  }
  out.to_string().replace_all(old=",)", new=")").replace_all(old=",]", new="]")
}

///|
fn generate(source : String) -> String raise {
  flat(@gen.render(Orm::{ }, [("models.mbt", source)]))
}

///|
fn refused(source : String) -> String {
  try {
    ignore(generate(source))
    ""
  } catch {
    e => "\{e}"
  }
}

///|
test "field types pick their column type and nullability" {
  let code = generate(
    (
      #|#orm.table
      #|pub struct HeroTeam {
      #|  #orm.column(primary_key=true, autoincrement=true)
      #|  id : Int64?
      #|  name : String
      #|  rank : Int
      #|  score : Double?
      #|  badge : Bytes
      #|  active : Bool
      #|}
    ),
  )
  assert_true(
    code.contains(flat("let hero_team_model : @moonorm.Model[HeroTeam]")),
  )
  assert_true(code.contains(flat("\"hero_team\"")))
  assert_true(
    code.contains(
      flat(
        "@moonorm.field(\"id\", BigIntType, h => h.id, primary_key=true, autoincrement=true)",
      ),
    ),
  )
  assert_true(
    code.contains(
      flat("@moonorm.field(\"name\", TextType, h => h.name, nullable=false)"),
    ),
  )
  assert_true(
    code.contains(
      flat("@moonorm.field(\"rank\", IntType, h => h.rank, nullable=false)"),
    ),
  )
  assert_true(
    code.contains(flat("@moonorm.field(\"score\", RealType, h => h.score)")),
  )
  assert_true(code.contains(flat("BlobType, h => h.badge")))
  assert_true(code.contains(flat("BoolType, h => h.active")))
  assert_true(code.contains(flat("id: r.read(0)")))
  assert_true(code.contains(flat("active: r.read(5)")))
  assert_true(
    code.contains(flat("pub fn HeroTeam::model() -> @moonorm.Model[HeroTeam]")),
  )
}

///|
test "column arguments reach the field call" {
  let code = generate(
    (
      #|#orm.table(name="heroes")
      #|struct Hero {
      #|  #orm.column(primary_key=true)
      #|  id : Int
      #|  #orm.column(name="secret_name", kind="varchar(64)", unique=true)
      #|  secret : String
      #|  #orm.column(default="0", check="age >= 0", check="age < 200")
      #|  age : Int
      #|  #orm.column(references="team.id", on_delete="CASCADE", on_update="SET NULL")
      #|  team_id : Int?
      #|  #orm.column(kind="datetime")
      #|  created : String
      #|}
    ),
  )
  assert_true(code.contains(flat("\"heroes\"")))
  assert_true(
    code.contains(
      flat(
        "@moonorm.field(\"id\", IntType, h => h.id, primary_key=true, nullable=false)",
      ),
    ),
  )
  assert_true(
    code.contains(
      flat(
        "@moonorm.field(\"secret_name\", VarcharType(64), h => h.secret, nullable=false, unique=true)",
      ),
    ),
  )
  assert_true(
    code.contains(flat("default=\"0\", checks=[\"age >= 0\", \"age < 200\"]")),
  )
  assert_true(
    code.contains(
      flat(
        "references=(\"team\", \"id\"), on_delete=\"CASCADE\", on_update=\"SET NULL\"",
      ),
    ),
  )
  assert_true(code.contains(flat("DateTimeType, h => h.created")))
  assert_true(code.contains(flat("fn Hero::model()")))
  assert_true(!code.contains(flat("pub fn Hero::model()")))
}

///|
test "a skipped field is filled from its default and holds no column" {
  let code = generate(
    (
      #|#orm.table
      #|struct Note {
      #|  #orm.skip
      #|  cache : Int
      #|  body : String
      #|}
    ),
  )
  assert_true(code.contains(flat("cache: Default::default()")))
  assert_true(code.contains(flat("body: r.read(0)")))
  assert_true(!code.contains(flat("\"cache\"")))
}

///|
test "a type of the program's own takes a column type by name" {
  let code = generate(
    (
      #|#orm.table
      #|struct User {
      #|  #orm.column(kind="text")
      #|  email : Email
      #|  #orm.column(kind="json")
      #|  prefs : Prefs?
      #|}
    ),
  )
  assert_true(code.contains(flat("TextType, h => h.email, nullable=false")))
  assert_true(code.contains(flat("JsonType, h => h.prefs)")))
}

///|
test "names follow snake case" {
  assert_eq(snake("Hero"), "hero")
  assert_eq(snake("HeroTeam"), "hero_team")
  assert_eq(snake("HTTPLog"), "http_log")
  assert_eq(snake("Log2Entry"), "log2_entry")
}

///|
test "type names map to column types" {
  assert_eq(column_named("VARCHAR(10)"), Some("VarcharType(10)"))
  assert_eq(column_named("varchar(0)"), None)
  assert_eq(column_named("varchar(x)"), None)
  assert_eq(column_named("bigint"), Some("BigIntType"))
  assert_eq(column_named("float"), None)
  assert_eq(inner_option("Option[Int]"), Some("Int"))
  assert_eq(inner_option("Int ?"), Some("Int"))
  assert_eq(inner_option("Int"), None)
}

///|
test "no annotated struct gives an empty file" {
  let code = generate(
    (
      #|struct Plain {
      #|  x : Int
      #|}
    ),
  )
  assert_true(!code.contains("from_fields"))
}

///|
test "mistakes are reported where they are written" {
  assert_true(
    refused(
      (
        #|#orm.table
        #|struct S {
        #|  #orm.column(primary_key=true, autoincrement=true)
        #|  id : Int64
        #|}
      ),
    ).contains("models.mbt:3:3: field `id`: an autoincrement key is `Int64?`"),
  )
  assert_true(
    refused(
      (
        #|#orm.table
        #|struct S {
        #|  #orm.column(autoincrement=true)
        #|  id : Int?
        #|}
      ),
    ).contains("`autoincrement` needs `primary_key=true`"),
  )
  assert_true(
    refused(
      (
        #|#orm.table
        #|struct S {
        #|  #orm.column(primary_key=true, autoincrement=true)
        #|  id : String?
        #|}
      ),
    ).contains("an autoincrement key is an integer"),
  )
  assert_true(
    refused(
      (
        #|#orm.table
        #|struct S {
        #|  when : Instant
        #|}
      ),
    ).contains(
      "models.mbt:1:1: field `when`: `Instant` has no default column type",
    ),
  )
  assert_true(
    refused(
      (
        #|#orm.table
        #|struct S {
        #|  #orm.column(kind="float")
        #|  x : Double
        #|}
      ),
    ).contains("`kind=\"float\"` is not a column type"),
  )
  assert_true(
    refused(
      (
        #|#orm.table
        #|struct S {
        #|  #orm.column(references="team")
        #|  t : Int
        #|}
      ),
    ).contains("`references` is `table.column`"),
  )
  assert_true(
    refused(
      (
        #|#orm.table
        #|struct S {
        #|  #orm.column(on_delete="CASCADE")
        #|  t : Int
        #|}
      ),
    ).contains("`on_delete` needs `references`"),
  )
  assert_true(
    refused(
      (
        #|#orm.table
        #|struct S {
        #|  #orm.column(name="x")
        #|  a : Int
        #|  x : Int
        #|}
      ),
    ).contains("declares column `x` twice"),
  )
  assert_true(
    refused(
      (
        #|#orm.table
        #|struct S {
        #|  #orm.skip
        #|  a : Int
        #|}
      ),
    ).contains("declares no column"),
  )
  assert_true(
    refused(
      (
        #|#orm.table
        #|struct S {
        #|  #orm.skip
        #|  #orm.column(name="b")
        #|  a : Int
        #|}
      ),
    ).contains("a skipped field takes no `#orm.column`"),
  )
  assert_true(
    refused(
      (
        #|struct S {
        #|  #orm.column(name="b")
        #|  a : Int
        #|}
      ),
    ).contains("`S` has no `#orm.table`"),
  )
  assert_true(
    refused(
      (
        #|#orm.table
        #|enum E { A }
      ),
    ).contains("goes on a struct"),
  )
  assert_true(
    refused(
      (
        #|#orm.tabel
        #|struct S { a : Int }
      ),
    ).contains("`#orm.tabel` is not a moonorm struct annotation"),
  )
  assert_true(
    refused(
      (
        #|#orm.table
        #|struct S {
        #|  #orm.column(nmae="b")
        #|  a : Int
        #|}
      ),
    ).contains("nmae"),
  )
  assert_true(
    refused(
      (
        #|#orm.table
        #|struct S {
        #|  #orm.column(type="text")
        #|  a : Int
        #|}
      ),
    ).contains("models.mbt:3:3: `#orm.column(type=\"text\")` does not parse"),
  )
}
