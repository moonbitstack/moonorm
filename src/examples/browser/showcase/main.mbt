// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Browser glue for the docs site, built as an executable so the JS backend
// bundles the whole library. Every function below calls the real library — the
// page never re-implements SQL rendering, type mapping, or the query builder.

// The small model the home page's seam ledger renders, field by field.

///|
pub struct User {
  id : Int64?
  name : String
  email : String
}

// The wider model the showcase page renders, so the constraints are visible.

///|
pub struct Account {
  id : Int64?
  email : String
  balance : Double
  team_id : Int64
  status : String
  level : Int32
}

///|
fn user_columns() -> Array[@schema.Column] {
  [
    @moonorm.column(
      "id",
      @schema.BigIntType,
      primary_key=true,
      autoincrement=true,
    ),
    @moonorm.column("name", @schema.TextType, nullable=false),
    @moonorm.column("email", @schema.TextType, nullable=false, unique=true),
  ]
}

///|
fn user() -> @moonorm.Model[User] {
  @moonorm.Model::new(
    "users",
    user_columns(),
    r => { id: r.read(0), name: r.read(1), email: r.read(2), },
    x => {
      [
        (
          "id",
          match x.id {
            Some(v) => @moondb.Int64(v)
            None => @moondb.Null
          },
        ),
        ("name", @moondb.Text(x.name)),
        ("email", @moondb.Text(x.email)),
      ]
    },
  )
}

///|
fn account() -> @moonorm.Model[Account] {
  @moonorm.Model::new(
    "accounts",
    [
      @moonorm.column(
        "id",
        @schema.BigIntType,
        primary_key=true,
        autoincrement=true,
      ),
      @moonorm.column("email", @schema.TextType, nullable=false, unique=true),
      @moonorm.column("balance", @schema.RealType),
      @moonorm.column(
        "team_id",
        @schema.BigIntType,
        references=("teams", "id"),
        on_delete="SET NULL",
      ),
      @moonorm.column(
        "status",
        @schema.TextType,
        nullable=false,
        default="'active'",
      ),
      @moonorm.column("level", @schema.IntType, checks=["level >= 0"]),
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
}

// d: 0 = Sqlite, 1 = Postgres, 2 = Mysql

///|
fn dialect_of(d : Int32) -> @query.Dialect {
  match d {
    1 => @query.Postgres
    2 => @query.Mysql
    _ => @query.Sqlite
  }
}

// One line per column of the home page's model: `name|SQL type|flags`.
// The flags are the column's own constraints, read back off the `Column`.

///|
pub fn demo_user_columns(d : Int32) -> String {
  let dialect = dialect_of(d)
  user_columns()
  .map(fn(c) {
    let mut flags = ""
    if c.primary_key {
      flags = flags + "primary key"
    }
    if c.nullable == false {
      flags = flags + " not null"
    }
    if c.unique {
      flags = flags + " unique"
    }
    c.name + "|" + c.col_type.sql_for(dialect) + "|" + flags
  })
  .join("\n")
}

// The three-dialect CREATE TABLE the home page shows under the seam.

///|
pub fn demo_user_ddl(d : Int32) -> String {
  user().create_table_sql_for(dialect_of(d))
}

// The showcase page: a model with constraints, in all three dialects.

///|
pub fn demo_ddl(d : Int32) -> String {
  account().create_table_sql_for(dialect_of(d))
}

///|
pub fn demo_query(use_where : Bool, use_limit : Bool) -> String {
  let mut q = account().select()
  if use_where {
    q = q.eq("email", @moondb.Text("ada@x.io"))
  }
  if use_limit {
    q = q.limit(10)
  }
  let (sql, params) = q.build()
  let ps = params.map(fn(v) { v.to_string() }).join(", ")
  sql + "\n\nparams: [" + ps + "]"
}

// Hand the real, compiled functions to the docs pages (no hand-written SQL).

///|
#cfg(target="js")
extern "js" fn register_demo(
  user_columns : (Int32) -> String,
  user_ddl : (Int32) -> String,
  ddl : (Int32) -> String,
  query : (Bool, Bool) -> String,
) =
  #| (userColumns, userDdl, ddl, query) => {
  #|   globalThis.moonormDemo = {
  #|     userColumns: userColumns,
  #|     userDdl: userDdl,
  #|     ddl: ddl,
  #|     query: query,
  #|   };
  #| }

///|
#cfg(target="js")
fn main {
  register_demo(demo_user_columns, demo_user_ddl, demo_ddl, demo_query)
}

///|
#cfg(not(target="js"))
fn main {

}
