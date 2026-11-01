// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A driver that remembers what it was asked and answers from a list, so the
/// statements and their bound values can be read off and checked.
struct Log {
  asked : Array[(String, Array[@moondb.Value])]
  rows : Array[@moondb.Row]
}

///|
impl @moondb.Driver for Log with fn execute(self, sql, params) {
  self.asked.push((sql, params))
  { rows_affected: 1L, last_insert_id: 41L, }
}

///|
impl @moondb.Driver for Log with fn query(self, sql, params) {
  self.asked.push((sql, params))
  self.rows
}

///|
impl @moondb.Driver for Log with fn begin(_) {

}

///|
impl @moondb.Driver for Log with fn commit(_) {

}

///|
impl @moondb.Driver for Log with fn rollback(_) {

}

///|
impl @moondb.Driver for Log with fn close(_) {

}

///|
fn expect(got : String, want : String) -> Unit {
  if got != want {
    abort("got \{got}, wanted \{want}")
  }
}

///|
/// SQL statements written as annotations on declared functions. `mapper.g.mbt` is
/// generated from `models.mbt` by `cmd/sql`; a project wires the generator as a
/// dev_build rule (see the README).
///
///     moon run src/examples/23-sql-mapper
fn main {
  run() catch {
    e => abort("\{e}")
  }
}

///|
fn run() -> Unit raise {
  let ada : @moondb.Row = {
    columns: ["id", "name", "age"],
    values: [Int(1), Text("ada"), Int(36)],
  }
  let log = Log::{ asked: [], rows: [ada], }
  let db : &@moondb.Driver = log
  let people = adults(db, 18)
  expect("\{people.length()} \{people[0].name}", "1 ada")
  expect(log.asked[0].0, "SELECT id, name, age FROM user WHERE age > ?")
  println(log.asked[0].0)
  let maybe = find(db, 1)
  expect(maybe.map(u => u.name).unwrap_or("nobody"), "ada")
  let renamed_row : @moondb.Row = {
    columns: ["id", "user_name", "age"],
    values: [Int(2), Text("grace"), Null],
  }
  let other = Log::{ asked: [], rows: [renamed_row], }
  let read = renamed(other)
  expect(read[0].name, "grace")
  expect(read[0].age.map(a => a.to_string()).unwrap_or("none"), "none")
  let count = Log::{
    asked: [],
    rows: [{ columns: ["count"], values: [Int(5)], }],
  }
  expect("\{total(count)}", "5")
  let user = { id: 0L, name: "linus", age: None, }
  expect("\{add(db, user)}", "41")
  println(log.asked.last().unwrap().0)
  let returned = Log::{
    asked: [],
    rows: [{ columns: ["id"], values: [Int(9)], }],
  }
  expect("\{add_returning(returned, user)}", "9")
  expect(
    returned.asked[0].0,
    "INSERT INTO user(name, age) VALUES($1, $2) RETURNING id",
  )
  println(returned.asked[0].0)
  expect("\{set_age(db, 1, 37)}", "1")
  remove(db, 1)
  println("\{log.asked.length()} statements on the log")
}
