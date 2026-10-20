///|
/// A row shaped like one PRAGMA table_info record: cid, name, type, notnull,
/// dflt_value, pk.
fn pragma_row(
  cid : Int32,
  name : String,
  ty : String,
  notnull : Int32,
  pk : Int32,
) -> @moondb.Row {
  {
    columns: ["cid", "name", "type", "notnull", "dflt_value", "pk"],
    values: [
      @moondb.Int(cid),
      @moondb.Text(name),
      @moondb.Text(ty),
      @moondb.Int(notnull),
      @moondb.Text(""),
      @moondb.Int(pk),
    ],
  }
}

///|
test "reflect_columns parses PRAGMA table_info into declared columns" {
  let rows = [
    pragma_row(0, "id", "INTEGER", 1, 1),
    pragma_row(1, "name", "TEXT", 1, 0),
    pragma_row(2, "score", "REAL", 0, 0),
  ]
  let cols = reflect_columns(rows)
  assert_eq(cols.length(), 3)
  assert_eq(cols[0].name, "id")
  assert_eq(cols[0].primary_key, true)
  assert_eq(cols[0].col_type == IntType, true)
  assert_eq(cols[1].name, "name")
  assert_eq(cols[1].nullable, false)
  assert_eq(cols[1].col_type == TextType, true)
  assert_eq(cols[2].nullable, true)
  assert_eq(cols[2].col_type == RealType, true)
}
