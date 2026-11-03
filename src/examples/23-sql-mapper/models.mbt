// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A row. Nothing here is annotated: a mapper reads a struct by its field names.
#derive(Eq, Debug)
pub struct User {
  id : Int64
  name : String
  age : Int32?
}

///|
/// `#{...}` binds a value; nothing is spliced into the statement. The function is
/// declared here and given its body in `mapper.g.mbt`.
#sql.select("SELECT id, name, age FROM user WHERE age > #{age}")
declare fn adults(db : &@moondb.Driver, age : Int32) -> Array[User] raise

///|
/// `T?` is at most one row, a bare `T` exactly one.
#sql.select("SELECT id, name, age FROM user WHERE id = #{id}")
declare fn find(db : &@moondb.Driver, id : Int64) -> User? raise

///|
/// A scalar reads the first column.
#sql.select("SELECT count(*) FROM user")
declare fn total(db : &@moondb.Driver) -> Int64 raise

///|
/// A column with another name than its field.
#sql.results(column="user_name", field="name")
#sql.select("SELECT id, name AS user_name, age FROM user")
declare fn renamed(db : &@moondb.Driver) -> Array[User] raise

///|
/// A path reaches into a parameter. An `Int64` from an insert is the new id.
#sql.insert("INSERT INTO user(name, age) VALUES(#{u.name}, #{u.age})")
declare fn add(db : &@moondb.Driver, u : User) -> Int64 raise

///|
/// PostgreSQL numbers its placeholders, and hands the new id back by `RETURNING`.
#sql.insert("INSERT INTO user(name, age) VALUES(#{u.name}, #{u.age})", returning="id", dialect="postgres")
declare fn add_returning(db : &@moondb.Driver, u : User) -> Int64 raise

///|
/// An `Int64` from an update or a delete is the rows it touched.
#sql.update("UPDATE user SET age = #{age} WHERE id = #{id}")
declare fn set_age(db : &@moondb.Driver, id : Int64, age : Int32) -> Int64 raise

///|
#sql.delete("DELETE FROM user WHERE id = #{id}")
declare fn remove(db : &@moondb.Driver, id : Int64) -> Unit raise
