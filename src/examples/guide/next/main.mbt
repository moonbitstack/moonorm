// The guide's last four steps, run for real: hooks, hybrids, inheritance and revision
// migrations. The page's code blocks come from the marked regions below and its output
// from what this prints, so neither can drift from the library.
//
//     moon run examples/guide/next

///|
priv struct Account {
  id : Int32
  email : String
  updated_by : String
}

///|
fn account_row(r : @moondb.Row) -> Account raise @moondb.DbError {
  { id: r.int(0), email: r.text(1), updated_by: r.text(2), }
}

///|
fn account_model() -> @moonorm.Model[Account] {
  let fields : Array[@moonorm.Field[Account]] = [
    @moonorm.field("id", @schema.IntType, a => a.id, primary_key=true),
    @moonorm.field("email", @schema.TextType, a => a.email, nullable=false),
    @moonorm.field("updated_by", @schema.TextType, a => a.updated_by),
  ]
  @moonorm.Model::from_fields("accounts", fields, account_row)
}

///|
fn hook_an_insert(sess : @moonorm.Session) -> Unit {
  // --8<-- [start:hooks]
  sess.on(@session.BeforeInsert, ctx => {
    // A creation stamp: the row is mutable here, and what is left behind is written.
    ctx.set_column("updated_by", @moondb.Text("import"))
  })
  sess.on(@session.AfterInsert, ctx => println(ctx.sql))
  // --8<-- [end:hooks]
}

///|
priv struct Person {
  first : String
  last : String
}

///|
fn full_name() -> @query.Hybrid[Person] {
  @query.hybrid("full_name", "{t}.first || ' ' || {t}.last", p => {
    @moondb.Text(p.first + " " + p.last)
  })
}

///|
fn filter_by_hybrid() -> String raise @moondb.DbError {
  // --8<-- [start:hybrid]
  let statement = @moonorm.select("people")
    .where_hybrid(full_name(), "=", @moondb.Text("Ada Lovelace"))
    .build()
  // The same definition, read off a record instead of by the database.
  let person : Person = { first: "Ada", last: "Lovelace", }
  println(full_name().value(person).to_string())
  statement.0
  // --8<-- [end:hybrid]
}

///|
priv struct Engineer {
  id : Int32
  name : String
  engineer_name : String
}

///|
fn engineer_row(r : @moondb.Row) -> Engineer raise @moondb.DbError {
  { id: r.int(0), name: r.text(1), engineer_name: r.text(2), }
}

///|
fn map_a_hierarchy() -> String {
  // --8<-- [start:inherit]
  let fields : Array[@moonorm.Field[Engineer]] = [
    @moonorm.field("id", @schema.IntType, e => e.id, primary_key=true),
    @moonorm.field("name", @schema.TextType, e => e.name, nullable=false),
    @moonorm.field("engineer_name", @schema.TextType, e => e.engineer_name),
  ]
  let model = @moonorm.Model::from_fields("engineer", fields, engineer_row).joined(
    parent_table="person",
    parent_columns=["id", "name"],
  )
  model.select().build().0
  // --8<-- [end:inherit]
}

///|
fn plan_revisions() -> String raise @moondb.DbError {
  // --8<-- [start:revision]
  let revisions : Array[@moonorm.Revision] = [
    @moonorm.Revision::new(
      id="0001",
      name="create_accounts",
      up=[
        @moonorm.create_table("accounts", [
          @moonorm.column("id", @schema.IntType, primary_key=true),
          @moonorm.column("email", @schema.VarcharType(255), nullable=false),
        ]),
      ],
      down=[@moonorm.drop_table("accounts")],
    ),
    @moonorm.Revision::new(
      id="0002",
      parents=["0001"],
      name="add_updated_by",
      up=[
        @moonorm.add_column(
          "accounts",
          @schema.column("updated_by", @schema.TextType),
        ),
      ],
      down=[@moonorm.drop_column("accounts", "updated_by")],
    ),
  ]
  let plan = @moonorm.Migrator::new().upgrade_sql(
    revisions,
    [],
    target="head",
    dialect=@query.Postgres,
  )
  for step in plan {
    for statement in step.statements {
      println(statement.sql)
    }
  }
  "0002"
  // --8<-- [end:revision]
}

///|
fn print_hooks() -> Unit {
  println("=== hooks ===")
  let driver = @moondb.MockDriver::new()
  let sess = @session.Session::new(driver)
  hook_an_insert(sess)
  sess.add_record(account_model(), { id: 1, email: "ada@x.io", updated_by: "", })
  let _ = try {
    sess.flush()
    Ok(())
  } catch {
    error => Err(error)
  }
  sess.close()
}

///|
/// A driver double, so the async step runs without a server: it records the
/// statements it is handed and answers queries from memory.
priv struct EchoDriver {
  log : Array[String]
}

///|
fn EchoDriver::new() -> EchoDriver {
  { log: [], }
}

///|
impl @moondb.AsyncDriver for EchoDriver with fn execute(
  self : EchoDriver,
  sql : String,
  _params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  self.log.push(sql)
  { rows_affected: 1L, last_insert_id: 0L, }
}

///|
impl @moondb.AsyncDriver for EchoDriver with fn query(
  self : EchoDriver,
  sql : String,
  _params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.log.push(sql)
  []
}

///|
impl @moondb.AsyncDriver for EchoDriver with fn begin(self : EchoDriver) -> Unit raise @moondb.DbError {
  self.log.push("BEGIN")
}

///|
impl @moondb.AsyncDriver for EchoDriver with fn commit(self : EchoDriver) -> Unit raise @moondb.DbError {
  self.log.push("COMMIT")
}

///|
impl @moondb.AsyncDriver for EchoDriver with fn rollback(self : EchoDriver) -> Unit raise @moondb.DbError {
  self.log.push("ROLLBACK")
}

///|
impl @moondb.AsyncDriver for EchoDriver with fn close(_self : EchoDriver) -> Unit {

}

///|
/// The asynchronous step runs as a test rather than a program: the pinned runtime has
/// no asynchronous entry point for every target, while a test is compiled and run on all
/// four. `moon test` prints what the test prints, and the page's output block is that
/// text — so the snippet and its result cannot drift apart.
async test "guide: the asynchronous session" {
  println("=== async ===")
  // --8<-- [start:async]
  let driver = EchoDriver::new()
  let sess = @session.AsyncSession::new(driver)
  sess.begin()
  sess.add_record(account_model(), {
    id: 1,
    email: "ada@x.io",
    updated_by: "import",
  })
  sess.commit()
  for line in driver.log {
    println(line)
  }
  // --8<-- [end:async]
}

///|
fn main {
  print_hooks()
  println("=== hybrid ===")
  let sql = filter_by_hybrid() catch { error => "error: " + error.to_string() }
  println(sql)
  println("=== inherit ===")
  println(map_a_hierarchy())
  println("=== revision ===")
  let last = plan_revisions() catch {
    error => {
      println("error: " + error.to_string())
      "failed"
    }
  }
  println("=== done ===")
  ignore(last)
}
