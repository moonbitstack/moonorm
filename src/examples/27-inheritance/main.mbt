// Inheritance mapping: one class hierarchy, three ways to store it.
//
//     moon run examples/27-inheritance
//
// Single table puts the whole hierarchy in one table behind a discriminator; joined
// table puts each class's own columns in its own table and joins them on the key;
// concrete table gives every class a table of its own and reads them together with a
// union. Each mapping is one `Model`, so the SQL is what a caller would get from any
// other model.

///|
struct Employee {
  id : Int32
  name : String
  kind : String
}

///|
struct Engineer {
  id : Int32
  name : String
  engineer_name : String
}

///|
struct Manager {
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
fn employee_model() -> @moonorm.Model[Employee] {
  let fields : Array[@moonorm.Field[Employee]] = [
    @moonorm.field("id", @schema.IntType, primary_key=true, e => e.id),
    @moonorm.field("name", @schema.TextType, nullable=false, e => e.name),
    @moonorm.field("kind", @schema.TextType, nullable=false, e => e.kind),
  ]
  @moonorm.Model::from_fields("employee", fields, employee_row)
}

///|
fn engineer_model() -> @moonorm.Model[Engineer] {
  let fields : Array[@moonorm.Field[Engineer]] = [
    @moonorm.field("id", @schema.IntType, primary_key=true, e => e.id),
    @moonorm.field("name", @schema.TextType, nullable=false, e => e.name),
    @moonorm.field("engineer_name", @schema.TextType, e => e.engineer_name),
  ]
  @moonorm.Model::from_fields("employee", fields, engineer_row).discriminate(
    column="kind",
    identity="engineer",
  )
}

///|
fn manager_model() -> @moonorm.Model[Manager] {
  let fields : Array[@moonorm.Field[Manager]] = [
    @moonorm.field("id", @schema.IntType, primary_key=true, e => e.id),
    @moonorm.field("name", @schema.TextType, nullable=false, e => e.name),
    @moonorm.field("manager_name", @schema.TextType, e => e.manager_name),
  ]
  @moonorm.Model::from_fields("employee", fields, manager_row).discriminate(
    column="kind",
    identity="manager",
  )
}

///|
/// The joined-table engineer: `id` and `name` in `person`, `engineer_name` in `engineer`.
struct JoinedEngineer {
  id : Int32
  name : String
  engineer_name : String
}

///|
fn joined_engineer_row(r : @moondb.Row) -> JoinedEngineer raise @moondb.DbError {
  { id: r.int(0), name: r.text(1), engineer_name: r.text(2), }
}

///|
fn joined_engineer_model() -> @moonorm.Model[JoinedEngineer] {
  let fields : Array[@moonorm.Field[JoinedEngineer]] = [
    @moonorm.field("id", @schema.IntType, primary_key=true, e => e.id),
    @moonorm.field("name", @schema.TextType, nullable=false, e => e.name),
    @moonorm.field("engineer_name", @schema.TextType, e => e.engineer_name),
  ]
  @moonorm.Model::from_fields("engineer", fields, joined_engineer_row).joined(
    parent_table="person",
    parent_columns=["id", "name"],
  )
}

///|
fn main {
  try {
    println("single table:")
    let (base, _) = employee_model().select().build()
    println("  base:     " + base)
    let (engineers, engineer_params) = engineer_model().select().build()
    println("  engineer: " + engineers)
    println(
      "            bound: " + engineer_params.map(v => v.to_string()).join(", "),
    )
    let (managers, _) = manager_model().select().build()
    println("  manager:  " + managers)
    println("")
    println("joined table:")
    let (joined, _) = joined_engineer_model().select().build()
    println("  read:  " + joined)
    // A joined write is two statements: the parent row, then the subclass row that
    // points at it.
    let engineer = joined_engineer_model()
    let grace : JoinedEngineer = {
      id: 4,
      name: "Grace",
      engineer_name: "grace",
    }
    let groups = engineer.split_columns((engineer.to_columns)(grace))
    println(
      "  write: insert into " +
      groups.map(group => group.0).join(", then into "),
    )
    let driver = @moondb.MockDriver::new()
    let sess = @moonorm.Session::new(driver)
    sess.add_record(engineer, grace)
    sess.flush()
    println(
      "         " + driver.row_count().to_string() + " statements executed",
    )
    println("")
    println(
      "concrete table: each class its own table, read together with a union",
    )
    let fields : Array[@moonorm.Field[Manager]] = [
      @moonorm.field("id", @schema.IntType, primary_key=true, m => m.id),
      @moonorm.field("name", @schema.TextType, nullable=false, m => m.name),
      @moonorm.field("manager_name", @schema.TextType, m => m.manager_name),
    ]
    let managers_only = @moonorm.Model::from_fields(
      "manager", fields, manager_row,
    )
    let (union_sql, _) = managers_only
      .select()
      .union_all(managers_only.select())
      .build()
    println("  " + union_sql)
    sess.close()
  } catch {
    error => println("error: " + error.to_string())
  }
}
