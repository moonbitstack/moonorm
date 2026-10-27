///|
test "Table descriptor: select() projects all declared columns" {
  let users : Table = { name: "users", columns: ["id", "name", "age"], }
  let (sql, _) = users.select().eq("age", Int(18)).build()
  assert_eq(sql, "SELECT id, name, age FROM users WHERE age = ?")
}

///|
test "Table descriptor: empty columns yields SELECT *" {
  let t : Table = { name: "logs", columns: [], }
  let (sql, _) = t.select().build()
  assert_eq(sql, "SELECT * FROM logs")
}
