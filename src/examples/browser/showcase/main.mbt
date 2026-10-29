// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Browser glue for the moonorm showcase, built as an executable so the JS
// backend bundles the whole library. Every function calls the real library —
// the page never re-implements the SQL rendering.

pub struct Account {
  id : Int64?
  email : String
  balance : Double
  team_id : Int64
  status : String
  level : Int
}

fn account() -> @moonorm.Model[Account] {
  @moonorm.Model::new(
    "accounts",
    [
      @moonorm.column("id", @schema.BigIntType, primary_key=true, autoincrement=true),
      @moonorm.column("email", @schema.TextType, nullable=false, unique=true),
      @moonorm.column("balance", @schema.RealType),
      @moonorm.column(
        "team_id",
        @schema.BigIntType,
        references=("teams", "id"),
        on_delete="SET NULL",
      ),
      @moonorm.column("status", @schema.TextType, nullable=false, default="'active'"),
      @moonorm.column("level", @schema.IntType, checks=["level >= 0"]),
    ],
    (r) => {
      {
        id: r.read(0),
        email: r.read(1),
        balance: r.read(2),
        team_id: r.read(3),
        status: r.read(4),
        level: r.read(5),
      }
    },
    (x) => {
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
pub fn demo_ddl(d : Int) -> String {
  let dialect = match d {
    1 => @query.Postgres
    2 => @query.Mysql
    _ => @query.Sqlite
  }
  account().create_table_sql_for(dialect)
}

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

// Hand the real, compiled functions to the docs page (no hand-written SQL).
extern "js" fn register_demo(
  ddl : (Int) -> String,
  query : (Bool, Bool) -> String,
) =
  #| (ddl, query) => {
  #|   globalThis.moonormDemo = { ddl: ddl, query: query };
  #| }

fn main {
  register_demo(demo_ddl, demo_query)
}
