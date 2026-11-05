// The three mappings, as the examples that introduce them present them: engineers and
// managers in the same table as an employee, in a table of their own next to a shared
// person table, or in tables of their own with no shared table at all.

///|
/// The base row of a single-table hierarchy: an id, a name and the discriminator.
priv struct Employee {
  id : Int32
  name : String
  kind : String
}

///|
/// An engineer row from the same table, carrying the one column only engineers have.
priv struct Engineer {
  id : Int32
  name : String
  engineer_name : String
}

///|
/// A manager row from the same table.
priv struct Manager {
  id : Int32
  name : String
  manager_name : String
}

///|
/// The engineer half: the person's two columns plus the one only engineers have.
priv struct JoinedEngineer {
  id : Int32
  name : String
  engineer_name : String
}

///|
/// The row readers are named rather than written inline: the records have the same
/// field names and shapes, and an inline literal would let the compiler pick any of
/// them.
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
fn joined_engineer_row(r : @moondb.Row) -> JoinedEngineer raise @moondb.DbError {
  { id: r.int(0), name: r.text(1), engineer_name: r.text(2), }
}

///|
/// The base model: every row of `employee`, the three columns every row has.
fn employee_model() -> Model[Employee] {
  let fields : Array[Field[Employee]] = [
    field("id", IntType, primary_key=true, e => e.id),
    field("name", TextType, nullable=false, e => e.name),
    field("kind", TextType, nullable=false, e => e.kind),
  ]
  Model::from_fields("employee", fields, employee_row)
}

///|
/// The engineer subclass: same table, its own columns, filtered by the discriminator.
fn engineer_model() -> Model[Engineer] {
  let fields : Array[Field[Engineer]] = [
    field("id", IntType, primary_key=true, e => e.id),
    field("name", TextType, nullable=false, e => e.name),
    field("engineer_name", TextType, e => e.engineer_name),
  ]
  Model::from_fields("employee", fields, engineer_row).discriminate(
    column="kind",
    identity="engineer",
  )
}

///|
/// The manager subclass of the same table.
fn manager_model() -> Model[Manager] {
  let fields : Array[Field[Manager]] = [
    field("id", IntType, primary_key=true, e => e.id),
    field("name", TextType, nullable=false, e => e.name),
    field("manager_name", TextType, e => e.manager_name),
  ]
  Model::from_fields("employee", fields, manager_row).discriminate(
    column="kind",
    identity="manager",
  )
}

///|
/// A joined-table subclass: id and name live in `person`, `engineer_name` in `engineer`.
fn joined_engineer_model() -> Model[JoinedEngineer] {
  let fields : Array[Field[JoinedEngineer]] = [
    field("id", IntType, primary_key=true, e => e.id),
    field("name", TextType, nullable=false, e => e.name),
    field("engineer_name", TextType, e => e.engineer_name),
  ]
  Model::from_fields("engineer", fields, joined_engineer_row).joined(
    parent_table="person",
    parent_columns=["id", "name"],
  )
}

///|
test "a single-table subclass reads its own rows and forces its discriminator on insert" {
  let engineer = engineer_model()
  // The projection is the subclass's columns plus the discriminator, declared here
  // even though the base table already carries it.
  assert_eq(engineer.column_names(), ["id", "name", "engineer_name", "kind"])
  let (sql, params) = engineer.select().build()
  assert_eq(
    sql, "SELECT id, name, engineer_name, kind FROM employee WHERE kind = ?",
  )
  assert_eq(params, [@moondb.Text("engineer")])
  // The insert carries the discriminator without the caller setting it.
  let ada : Engineer = { id: 1, name: "Ada", engineer_name: "ada", }
  let pairs = (engineer.to_columns)(ada)
  assert_eq(pairs, [
    ("id", @moondb.Int(1)),
    ("name", @moondb.Text("Ada")),
    ("engineer_name", @moondb.Text("ada")),
    ("kind", @moondb.Text("engineer")),
  ])
}

///|
test "the base model still reads every row, and the two subclasses filter the same table" {
  let (base, _) = employee_model().select().build()
  assert_eq(base, "SELECT id, name, kind FROM employee")
  let (engineers, engineer_params) = engineer_model().select().build()
  let (managers, manager_params) = manager_model().select().build()
  assert_eq(engineers.contains("WHERE kind = ?"), true)
  assert_eq(engineer_params, [@moondb.Text("engineer")])
  assert_eq(managers.contains("WHERE kind = ?"), true)
  assert_eq(manager_params, [@moondb.Text("manager")])
}

///|
test "a joined-table subclass joins its parent and reads the two halves in order" {
  let engineer = joined_engineer_model()
  assert_eq(engineer.is_joined(), true)
  assert_eq(engineer.parent_table(), "person")
  assert_eq(engineer.parent_key(), "id")
  assert_eq(engineer.parent_fk(), "id")
  let (sql, _) = engineer.select().build()
  assert_eq(
    sql, "SELECT person.id, person.name, engineer.engineer_name FROM engineer JOIN person ON person.id = engineer.id",
  )
}

///|
test "a joined-table write splits into parent and subclass, in that order" {
  let groups = joined_engineer_model().split_columns([
    ("id", @moondb.Int(3)),
    ("name", @moondb.Text("Grace")),
    ("engineer_name", @moondb.Text("grace")),
  ])
  assert_eq(groups.length(), 2)
  assert_eq(groups[0].0, "person")
  assert_eq(groups[0].1, [
    ("id", @moondb.Int(3)),
    ("name", @moondb.Text("Grace")),
  ])
  // The subclass row carries the key too: that column is the foreign key.
  assert_eq(groups[1].0, "engineer")
  assert_eq(groups[1].1, [
    ("engineer_name", @moondb.Text("grace")),
    ("id", @moondb.Int(3)),
  ])
}

///|
test "a joined-table subclass addresses its rows by the shared key, named once" {
  // Both tables have a column called id; the row has one key.
  assert_eq(joined_engineer_model().pk_columns(), ["id"])
}

///|
test "a model that is not joined splits into one group and has no parent" {
  let employee = employee_model()
  assert_eq(employee.is_joined(), false)
  assert_eq(employee.parent_table(), "")
  let groups = employee.split_columns([("id", @moondb.Int(1))])
  assert_eq(groups.length(), 1)
  assert_eq(groups[0].0, "employee")
}

///|
/// Concrete inheritance has no shared table: each class is a model over its own table,
/// and a polymorphic read is the union of the per-class reads.
test "concrete inheritance is one model per table, read together with a union" {
  let fields : Array[Field[Manager]] = [
    field("id", IntType, primary_key=true, m => m.id),
    field("name", TextType, nullable=false, m => m.name),
    field("manager_name", TextType, m => m.manager_name),
  ]
  let managers = Model::from_fields("manager", fields, manager_row)
  let (union_sql, _) = managers.select().union_all(managers.select()).build()
  assert_eq(
    union_sql, "SELECT id, name, manager_name FROM manager UNION ALL SELECT id, name, manager_name FROM manager",
  )
}
