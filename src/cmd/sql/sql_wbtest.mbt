// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Code without spaces, line breaks or the trailing commas the printer adds.
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
let user : String =
  #|pub struct User {
  #|  id : Int64
  #|  name : String
  #|  age : Int32?
  #|}
  #|

///|
fn generate(source : String) -> String raise {
  flat(@gen.render(Sql::{ }, [("m.mbt", user + source)]))
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
test "a select of a struct reads each field by its column" {
  let source =
    #|#sql.select("SELECT id, name, age FROM user WHERE age > #{age}")
    #|declare fn adults(db : &@moondb.Driver, age : Int32) -> Array[User] raise
  let code = generate(source)
  assert_true(
    code.contains(
      flat("fn adults(db : &@moondb.Driver, age : Int32) -> Array[User] raise"),
    ),
  )
  assert_true(
    code.contains(flat("WHERE age > ?\", [@moondb.ToValue::to_value(age)])")),
  )
  assert_true(
    code.contains(
      flat(
        "id: @mapper.column(row, \"id\"), name: @mapper.column(row, \"name\")",
      ),
    ),
  )
  assert_true(code.contains("rows.map"))
}

///|
test "postgres numbers its placeholders, the others use a question mark" {
  let source =
    #|#sql.select("SELECT id, name, age FROM user WHERE a = #{a} AND b = #{b}", dialect="postgres")
    #|declare fn f(db : &@moondb.Driver, a : Int32, b : Int32) -> Array[User] raise
    #|
    #|#sql.select("SELECT id, name, age FROM user WHERE a = #{a} AND b = #{b}", dialect="mysql")
    #|declare fn g(db : &@moondb.Driver, a : Int32, b : Int32) -> Array[User] raise
  let code = generate(source)
  assert_true(code.contains(flat("WHERE a = $1 AND b = $2")))
  assert_true(code.contains(flat("WHERE a = ? AND b = ?")))
}

///|
test "a path into a parameter binds that field" {
  let source =
    #|#sql.insert("INSERT INTO user(name) VALUES(#{u.name})")
    #|declare fn add(db : &@moondb.Driver, u : User) -> Unit raise
  assert_true(generate(source).contains("to_value(u.name)"))
}

///|
test "a quoted string is left alone" {
  let source =
    #|#sql.update("UPDATE user SET name = '#{x}?' WHERE id = #{id}")
    #|declare fn f(db : &@moondb.Driver, id : Int64) -> Unit raise
  assert_true(
    generate(source).contains(flat("SET name = '#{x}?' WHERE id = ?")),
  )
}

///|
test "what a select returns decides how the rows are read" {
  let source =
    #|#sql.select("SELECT id, name, age FROM user WHERE id = #{id}")
    #|declare fn one_user(db : &@moondb.Driver, id : Int64) -> User raise
    #|
    #|#sql.select("SELECT id, name, age FROM user WHERE id = #{id}")
    #|declare fn maybe(db : &@moondb.Driver, id : Int64) -> User? raise
    #|
    #|#sql.select("SELECT count(*) FROM user")
    #|declare fn total(db : &@moondb.Driver) -> Int64 raise
    #|
    #|#sql.select("SELECT name FROM user")
    #|declare fn names(db : &@moondb.Driver) -> Array[String] raise
  let code = generate(source)
  assert_true(code.contains("@mapper.one(rows)"))
  assert_true(code.contains("@mapper.optional(rows)"))
  assert_true(code.contains("@mapper.first(row)"))
}

///|
test "an aliased column and `#sql.results` both name the field's column" {
  let source =
    #|#sql.results(column="user_name", field="name")
    #|#sql.select("SELECT id, nick AS user_name, age FROM user")
    #|declare fn all(db : &@moondb.Driver) -> Array[User] raise
  assert_true(
    generate(source).contains(flat("name: @mapper.column(row, \"user_name\")")),
  )
}

///|
test "a field left out of the select is refused unless it may be absent" {
  let source =
    #|#sql.select("SELECT id, age FROM user")
    #|declare fn f(db : &@moondb.Driver) -> Array[User] raise
  assert_true(refused(source).contains("needs a column `name`"))
  let source =
    #|#sql.select("SELECT id, name FROM user")
    #|declare fn f(db : &@moondb.Driver) -> Array[User] raise
  assert_eq(refused(source), "")
  let source =
    #|#sql.select("SELECT * FROM user")
    #|declare fn f(db : &@moondb.Driver) -> Array[User] raise
  assert_eq(refused(source), "")
}

///|
test "insert, update and delete give back what they are declared to" {
  let source =
    #|#sql.insert("INSERT INTO user(name) VALUES(#{name})")
    #|declare fn add(db : &@moondb.Driver, name : String) -> Int64 raise
    #|
    #|#sql.update("UPDATE user SET name = #{name}")
    #|declare fn rename(db : &@moondb.Driver, name : String) -> Int64 raise
    #|
    #|#sql.delete("DELETE FROM user")
    #|declare fn clear(db : &@moondb.Driver) -> Unit raise
  let code = generate(source)
  assert_true(code.contains("result.last_insert_id"))
  assert_true(code.contains("result.rows_affected"))
  assert_true(code.contains("ignore(result)"))
}

///|
test "returning asks the database for the column" {
  let source =
    #|#sql.insert("INSERT INTO user(name) VALUES(#{name})", returning="id")
    #|declare fn add(db : &@moondb.Driver, name : String) -> Int64 raise
  let code = generate(source)
  assert_true(code.contains(flat("VALUES(?) RETURNING id")))
  assert_true(code.contains("@mapper.first(row)"))
}

///|
test "an async driver makes an async function" {
  let source =
    #|#sql.select("SELECT name FROM user")
    #|declare async fn names(db : &@moondb.AsyncDriver) -> Array[String] raise
  assert_true(generate(source).contains("asyncfnnames"))
}

///|
test "what cannot be generated is refused, with where" {
  let cases : Array[(String, String)] = [
    (
      "#sql.select(\"SELECT 1\")\nfn f(db : &@moondb.Driver) -> Int64 raise { 1 }",
      "goes on a `declare fn`",
    ),
    (
      "#sql.select(\"SELECT 1\")\ndeclare fn f(x : Int) -> Int64 raise", "no parameter is a",
    ),
    (
      "#sql.select(\"SELECT 1\")\ndeclare fn f(db : &@moondb.Driver) -> Int64", "declare `f` with `raise`",
    ),
    (
      "#sql.select(\"SELECT #{x}\")\ndeclare fn f(db : &@moondb.Driver) -> Int64 raise",
      "names no parameter",
    ),
    (
      "#sql.select(\"SELECT #{\")\ndeclare fn f(db : &@moondb.Driver) -> Int64 raise",
      "never closed",
    ),
    (
      "#sql.select(\"SELECT ${x}\")\ndeclare fn f(db : &@moondb.Driver) -> Int64 raise",
      "there is no `${...}`",
    ),
    (
      "#sql.select(\"SELECT ?\")\ndeclare fn f(db : &@moondb.Driver) -> Int64 raise",
      "not as a placeholder",
    ),
    (
      "#sql.select(\"SELECT $1\")\ndeclare fn f(db : &@moondb.Driver) -> Int64 raise",
      "not as a placeholder",
    ),
    (
      "#sql.select(\"SELECT 1\", dialect=\"oracle\")\ndeclare fn f(db : &@moondb.Driver) -> Int64 raise",
      "`dialect` is",
    ),
    (
      "#sql.select(\"SELECT 1\")\ndeclare fn f(db : &@moondb.Driver) -> Unit raise",
      "returns what it reads",
    ),
    (
      "#sql.select(\"SELECT 1\")\ndeclare fn f(db : &@moondb.Driver) -> Thing raise",
      "neither a column type nor a struct",
    ),
    (
      "#sql.select(\"SELECT 1\")\n#sql.delete(\"DELETE\")\ndeclare fn f(db : &@moondb.Driver) -> Unit raise",
      "exactly one statement",
    ),
    (
      "#sql.results(column=\"a\", field=\"b\")\ndeclare fn f(db : &@moondb.Driver) -> Unit raise",
      "exactly one statement",
    ),
    (
      "#sql.results(column=\"a\", field=\"b\")\n#sql.delete(\"DELETE\")\ndeclare fn f(db : &@moondb.Driver) -> Unit raise",
      "is for `#sql.select`",
    ),
    (
      "#sql.results(column=\"a\", field=\"nope\")\n#sql.select(\"SELECT * FROM user\")\ndeclare fn f(db : &@moondb.Driver) -> Array[User] raise",
      "has no field `nope`",
    ),
    (
      "#sql.results(column=\"a\", field=\"b\")\n#sql.select(\"SELECT 1\")\ndeclare fn f(db : &@moondb.Driver) -> Int64 raise",
      "renames a struct's fields",
    ),
    (
      "#sql.update(\"UPDATE t SET a = 1\", returning=\"id\")\ndeclare fn f(db : &@moondb.Driver) -> Int64 raise",
      "is for `#sql.insert`",
    ),
    (
      "#sql.insert(\"INSERT INTO t VALUES(1)\", returning=\"id\", dialect=\"mysql\")\ndeclare fn f(db : &@moondb.Driver) -> Int64 raise",
      "MySQL has no RETURNING",
    ),
    (
      "#sql.update(\"UPDATE t SET a = 1\")\ndeclare fn f(db : &@moondb.Driver) -> String raise",
      "returns `Unit` or `Int64`",
    ),
    (
      "#sql.select(\"SELECT 1\")\ndeclare fn f(db : &@moondb.AsyncDriver) -> Int64 raise",
      "needs `declare async fn`",
    ),
    (
      "#sql.select(\"SELECT 1\")\ndeclare async fn f(db : &@moondb.Driver) -> Int64 raise",
      "is not async",
    ),
    (
      "#sql.table(\"x\")\ndeclare fn f(db : &@moondb.Driver) -> Unit raise", "is not a moonorm annotation",
    ),
    ("#sql.select(\"x\")\nstruct S {\n  a : Int\n}", "goes on a `declare fn`"),
    (
      "#sql.select(type=\"x\")\ndeclare fn f(db : &@moondb.Driver) -> Unit raise",
      "does not parse",
    ),
  ]
  for one in cases {
    let (source, want) = one
    let got = refused(source)
    assert_true(got.contains(want), msg="\{source}\nwanted \{want}\ngot \{got}")
  }
}
