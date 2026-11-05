///|
/// A person row as a joined-table subclass reads it: the parent's two columns and the
/// subclass's one.
#derive(Eq, Debug)
struct Staff {
  id : Int32
  name : String
  staff_name : String
}

///|
fn staff_row(r : @moondb.Row) -> Staff raise @moondb.DbError {
  { id: r.int(0), name: r.text(1), staff_name: r.text(2), }
}

///|
/// A joined-table model: `id` and `name` in `person`, `staff_name` in `staff`.
fn staff_model() -> @schema.Model[Staff] {
  let fields : Array[@schema.Field[Staff]] = [
    @schema.field("id", IntType, primary_key=true, s => s.id),
    @schema.field("name", TextType, nullable=false, s => s.name),
    @schema.field("staff_name", TextType, s => s.staff_name),
  ]
  @schema.Model::from_fields("staff", fields, staff_row).joined(
    parent_table="person",
    parent_columns=["id", "name"],
  )
}

///|
/// The row a joined-table insert writes: the parent's half first, then the subclass's,
/// which is the only order a foreign key allows.
test "a joined-table insert writes the parent row and then the subclass row" {
  let drv = hook_driver()
  let sess = Session::new(drv)
  let model = staff_model()
  sess.add_record(model, { id: 4, name: "Ada", staff_name: "ada", })
  sess.flush()
  assert_eq(drv.writes.map(entry => entry.0), [
    "INSERT INTO person (id, name) VALUES (?, ?)", "INSERT INTO staff (staff_name, id) VALUES (?, ?)",
  ])
  assert_eq(drv.writes[0].1, [@moondb.Int(4), @moondb.Text("Ada")])
  assert_eq(drv.writes[1].1, [@moondb.Text("ada"), @moondb.Int(4)])
}

///|
test "a joined-table update sets each table's columns and keys on the shared id" {
  let drv = hook_driver()
  let sess = Session::new(drv)
  sess.update_record(staff_model(), {
    id: 5,
    name: "Grace",
    staff_name: "grace",
  })
  sess.flush()
  assert_eq(drv.writes.map(entry => entry.0), [
    "UPDATE person SET name = ? WHERE id = ?", "UPDATE staff SET staff_name = ? WHERE id = ?",
  ])
}

///|
test "a joined-table delete removes the subclass row before the parent" {
  let drv = hook_driver()
  let sess = Session::new(drv)
  sess.delete_record(staff_model(), { id: 6, name: "Alan", staff_name: "alan", })
  sess.flush()
  assert_eq(drv.writes.map(entry => entry.0), [
    "DELETE FROM staff WHERE id = ?", "DELETE FROM person WHERE id = ?",
  ])
  assert_eq(drv.writes[0].1, [@moondb.Int(6)])
}

///|
test "a single-table subclass writes its discriminator and reads only its own rows" {
  let drv = hook_driver()
  let sess = Session::new(drv)
  let fields : Array[@schema.Field[Staff]] = [
    @schema.field("id", IntType, primary_key=true, s => s.id),
    @schema.field("name", TextType, nullable=false, s => s.name),
    @schema.field("staff_name", TextType, s => s.staff_name),
  ]
  let model = @schema.Model::from_fields("employee", fields, staff_row).discriminate(
    column="kind",
    identity="staff",
  )
  sess.add_record(model, { id: 7, name: "Katherine", staff_name: "k", })
  sess.flush()
  assert_eq(
    drv.writes[0].0,
    "INSERT INTO employee (id, name, staff_name, kind) VALUES (?, ?, ?, ?)",
  )
  assert_eq(drv.writes[0].1[3], @moondb.Text("staff"))
}
