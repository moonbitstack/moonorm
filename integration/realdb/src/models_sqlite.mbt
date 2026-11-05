// Hybrid attributes and the three inheritance mappings, on a real SQLite file. The
// point of each test is that the two readings agree with what the database actually
// returns — a hybrid's SQL expression and its in-memory projection, and each mapping's
// read path against what its write path stored.

///|
priv struct Person {
  id : Int32
  first : String
  last : String
  age : Int32
}

///|
fn person_row(r : @moondb.Row) -> Person raise @moondb.DbError {
  { id: r.int(0), first: r.text(1), last: r.text(2), age: r.int(3), }
}

///|
fn person_model() -> @schema.Model[Person] {
  let fields : Array[@schema.Field[Person]] = [
    @schema.field("id", @schema.IntType, p => p.id, primary_key=true),
    @schema.field("first", @schema.TextType, p => p.first, nullable=false),
    @schema.field("last", @schema.TextType, p => p.last, nullable=false),
    @schema.field("age", @schema.IntType, p => p.age, nullable=false),
  ]
  @schema.Model::from_fields("people", fields, person_row)
}

///|
fn full_name() -> @query.Hybrid[Person] {
  @query.hybrid("full_name", "{t}.first || ' ' || {t}.last", p => {
    @moondb.Text(p.first + " " + p.last)
  })
}

///|
fn is_adult() -> @query.Hybrid[Person] {
  @query.hybrid("is_adult", "{t}.age >= 18", p => @moondb.Bool(p.age >= 18))
}

///|
test "a hybrid's SQL reading selects the rows its value reading names" {
  let driver = @sqlite.SqliteDriver::open(":memory:") catch {
    error => abort("open failed: " + error.to_string())
  }
  let sess = @session.Session::new(driver)
  try {
    let model = person_model()
    sess.create_table(model, if_not_exists=true) |> ignore
    let people = [
      { id: 1, first: "Ada", last: "Lovelace", age: 36, },
      { id: 2, first: "Alan", last: "Turing", age: 41, },
      { id: 3, first: "Tim", last: "Berners-Lee", age: 17, },
    ]
    for person in people {
      sess.insert_record(model, person) |> ignore
    }
    let name = full_name()
    let adult = is_adult()
    // The same predicate, evaluated by SQLite and by the hybrid's own reader.
    let by_sql = sess.fetch_as(
      model,
      model.select().where_hybrid(name, "=", @moondb.Text("Ada Lovelace")),
    )
    let by_value = people.filter(p => {
      name.value(p) == @moondb.Text("Ada Lovelace")
    })
    assert_eq(by_sql.length(), by_value.length())
    assert_eq(by_sql[0].id, by_value[0].id)
    let adults_by_sql = sess.fetch_as(
      model,
      model.select().where_hybrid(adult, "=", @moondb.Bool(true)),
    )
    let adults_by_value = people.filter(p => {
      adult.value(p) == @moondb.Bool(true)
    })
    assert_eq(adults_by_sql.length(), adults_by_value.length())
    // Ordering by the computed expression, which has no column of its own.
    let ordered = sess.fetch_as(
      model,
      model.select().order_hybrid(name, @query.Asc),
    )
    assert_eq(ordered.map(p => p.first), ["Ada", "Alan", "Tim"])
    sess.close()
  } catch {
    error => {
      sess.close()
      abort("hybrid test failed: " + error.to_string())
    }
  }
}

///|
priv struct Employee {
  id : Int32
  name : String
  kind : String
}

///|
priv struct Engineer {
  id : Int32
  name : String
  engineer_name : String
}

///|
priv struct Manager {
  id : Int32
  name : String
  manager_name : String
}

///|
fn employee_row(r : @moondb.Row) -> Employee raise @moondb.DbError {
  { id: r.int(0), name: r.text(1), kind: r.text(2), }
}

///|
fn engineer_row(r : @moondb.Row) -> Engineer raise @moondb.DbError {
  { id: r.int(0), name: r.text(1), engineer_name: r.text(2), }
}

///|
fn manager_row(r : @moondb.Row) -> Manager raise @moondb.DbError {
  { id: r.int(0), name: r.text(1), manager_name: r.text(2), }
}

///|
fn employee_model() -> @schema.Model[Employee] {
  let fields : Array[@schema.Field[Employee]] = [
    @schema.field("id", @schema.IntType, e => e.id, primary_key=true),
    @schema.field("name", @schema.TextType, e => e.name, nullable=false),
    @schema.field("kind", @schema.TextType, e => e.kind, nullable=false),
  ]
  @schema.Model::from_fields("employee", fields, employee_row)
}

///|
fn engineer_model() -> @schema.Model[Engineer] {
  let fields : Array[@schema.Field[Engineer]] = [
    @schema.field("id", @schema.IntType, e => e.id, primary_key=true),
    @schema.field("name", @schema.TextType, e => e.name, nullable=false),
    @schema.field("engineer_name", @schema.TextType, e => e.engineer_name),
  ]
  @schema.Model::from_fields("employee", fields, engineer_row).discriminate(
    column="kind",
    identity="engineer",
  )
}

///|
fn manager_model() -> @schema.Model[Manager] {
  let fields : Array[@schema.Field[Manager]] = [
    @schema.field("id", @schema.IntType, e => e.id, primary_key=true),
    @schema.field("name", @schema.TextType, e => e.name, nullable=false),
    @schema.field("manager_name", @schema.TextType, e => e.manager_name),
  ]
  @schema.Model::from_fields("employee", fields, manager_row).discriminate(
    column="kind",
    identity="manager",
  )
}

///|
test "single-table inheritance reads back what each subclass wrote" {
  let driver = @sqlite.SqliteDriver::open(":memory:") catch {
    error => abort("open failed: " + error.to_string())
  }
  let sess = @session.Session::new(driver)
  try {
    let shared = [
      @schema.column("id", @schema.IntType, primary_key=true),
      @schema.column("name", @schema.TextType, nullable=false),
      @schema.column("kind", @schema.TextType, nullable=false),
      @schema.column("engineer_name", @schema.TextType),
      @schema.column("manager_name", @schema.TextType),
    ]
    sess.execute(@schema.create_table_sql("employee", shared, @query.Sqlite), [])
    |> ignore
    let ada : Engineer = { id: 1, name: "Ada", engineer_name: "ada", }
    let grace : Manager = { id: 2, name: "Grace", manager_name: "grace", }
    sess.insert_record(engineer_model(), ada) |> ignore
    sess.insert_record(manager_model(), grace) |> ignore
    // The base model sees both rows; each subclass sees only its own.
    assert_eq(sess.all(employee_model()).length(), 2)
    let engineers = sess.all(engineer_model())
    assert_eq(engineers.length(), 1)
    assert_eq(engineers[0].engineer_name, "ada")
    let managers = sess.all(manager_model())
    assert_eq(managers.length(), 1)
    assert_eq(managers[0].manager_name, "grace")
    // The discriminator was written by the model, not by the caller.
    let rows = sess.query("SELECT kind FROM employee ORDER BY id", [])
    assert_eq(rows[0].text(0), "engineer")
    assert_eq(rows[1].text(0), "manager")
    sess.close()
  } catch {
    error => {
      sess.close()
      abort("single-table inheritance failed: " + error.to_string())
    }
  }
}

///|
priv struct JoinedEngineer {
  id : Int32
  name : String
  engineer_name : String
}

///|
fn joined_engineer_row(r : @moondb.Row) -> JoinedEngineer raise @moondb.DbError {
  { id: r.int(0), name: r.text(1), engineer_name: r.text(2), }
}

///|
fn joined_engineer_model() -> @schema.Model[JoinedEngineer] {
  let fields : Array[@schema.Field[JoinedEngineer]] = [
    @schema.field("id", @schema.IntType, e => e.id, primary_key=true),
    @schema.field("name", @schema.TextType, e => e.name, nullable=false),
    @schema.field("engineer_name", @schema.TextType, e => e.engineer_name),
  ]
  @schema.Model::from_fields("engineer", fields, joined_engineer_row).joined(
    parent_table="person",
    parent_columns=["id", "name"],
  )
}

///|
test "joined-table inheritance writes two rows and reads them back as one record" {
  let driver = @sqlite.SqliteDriver::open(":memory:") catch {
    error => abort("open failed: " + error.to_string())
  }
  let sess = @session.Session::new(driver)
  try {
    sess.execute(
      @schema.create_table_sql(
        "person",
        [
          @schema.column("id", @schema.IntType, primary_key=true),
          @schema.column("name", @schema.TextType, nullable=false),
        ],
        @query.Sqlite,
      ),
      [],
    )
    |> ignore
    sess.execute(
      @schema.create_table_sql(
        "engineer",
        [
          @schema.column(
            "id",
            @schema.IntType,
            primary_key=true,
            references=("person", "id"),
          ),
          @schema.column("engineer_name", @schema.TextType, nullable=false),
        ],
        @query.Sqlite,
      ),
      [],
    )
    |> ignore
    let model = joined_engineer_model()
    let grace : JoinedEngineer = {
      id: 4,
      name: "Grace",
      engineer_name: "grace",
    }
    sess.add_record(model, grace)
    sess.flush()
    // One read joins the halves back together.
    let engineers = sess.all(model)
    assert_eq(engineers.length(), 1)
    assert_eq(engineers[0].name, "Grace")
    assert_eq(engineers[0].engineer_name, "grace")
    // Each table holds its own half.
    let parent = sess.query("SELECT name FROM person", [])
    let child = sess.query("SELECT engineer_name FROM engineer", [])
    assert_eq(parent[0].text(0), "Grace")
    assert_eq(child[0].text(0), "grace")
    // An update splits the same way: one statement per table.
    let renamed : JoinedEngineer = {
      id: 4,
      name: "Grace H.",
      engineer_name: "gh",
    }
    sess.update_record(model, renamed)
    sess.flush()
    let again = sess.all(model)
    assert_eq(again[0].name, "Grace H.")
    assert_eq(again[0].engineer_name, "gh")
    // A delete takes the subclass row first, then the parent it pointed at.
    sess.delete_record(model, again[0])
    sess.flush()
    assert_eq(sess.query("SELECT id FROM person", []).length(), 0)
    assert_eq(sess.query("SELECT id FROM engineer", []).length(), 0)
    sess.close()
  } catch {
    error => {
      sess.close()
      abort("joined-table inheritance failed: " + error.to_string())
    }
  }
}

///|
test "concrete inheritance reads two tables as one union" {
  let driver = @sqlite.SqliteDriver::open(":memory:") catch {
    error => abort("open failed: " + error.to_string())
  }
  let sess = @session.Session::new(driver)
  try {
    let engineer_fields : Array[@schema.Field[Engineer]] = [
      @schema.field("id", @schema.IntType, e => e.id, primary_key=true),
      @schema.field("name", @schema.TextType, e => e.name, nullable=false),
      @schema.field("engineer_name", @schema.TextType, e => e.engineer_name),
    ]
    let concrete_engineer = @schema.Model::from_fields(
      "engineer", engineer_fields, engineer_row,
    )
    let manager_fields : Array[@schema.Field[Manager]] = [
      @schema.field("id", @schema.IntType, m => m.id, primary_key=true),
      @schema.field("name", @schema.TextType, m => m.name, nullable=false),
      @schema.field("manager_name", @schema.TextType, m => m.manager_name),
    ]
    let concrete_manager = @schema.Model::from_fields(
      "manager", manager_fields, manager_row,
    )
    sess.create_table(concrete_engineer) |> ignore
    sess.create_table(concrete_manager) |> ignore
    let ada : Engineer = { id: 1, name: "Ada", engineer_name: "ada", }
    let grace : Manager = { id: 1, name: "Grace", manager_name: "grace", }
    sess.insert_record(concrete_engineer, ada) |> ignore
    sess.insert_record(concrete_manager, grace) |> ignore
    assert_eq(sess.all(concrete_engineer)[0].engineer_name, "ada")
    assert_eq(sess.all(concrete_manager)[0].manager_name, "grace")
    // The polymorphic read is the union of the two, projected to the shared columns.
    let union = @query.select("engineer")
      .column("id")
      .column("name")
      .union_all(@query.select("manager").column("id").column("name"))
    let rows = sess.fetch(union)
    assert_eq(rows.length(), 2)
    sess.close()
  } catch {
    error => {
      sess.close()
      abort("concrete inheritance failed: " + error.to_string())
    }
  }
}
