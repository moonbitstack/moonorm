///|
/// The field-based declarative path: `Model::from_fields` derives the column list, the
/// `CREATE TABLE` DDL, and the `INSERT` binding from a `[Field]` array — each `field`
/// pairs column metadata with the encoder that pulls its value out of a record. You
/// supply only the `from_row` decoder (the record constructor MoonBit cannot synthesise
/// without reflection). This is the shape moonctl's model generator emits. `Field::name`
/// exposes the per-field metadata; then a `Session` round trip over `@moondb.MockDriver`.
///
///     moon run examples/12-declarative-fields
struct Hero {
  id : Int32
  name : String
  power : Int32
}

///|
let heroes : @moonorm.Model[Hero] = @moonorm.Model::from_fields(
  "heroes",
  [
    @moonorm.field("id", IntType, h => @moondb.Int(h.id), primary_key=true),
    @moonorm.field("name", TextType, h => @moondb.Text(h.name), nullable=false),
    @moonorm.field("power", IntType, h => @moondb.Int(h.power)),
  ],
  r => { id: r.int(0), name: r.text(1), power: r.int(2), },
)

///|
fn render(v : @moondb.Value) -> String {
  match v {
    Null => "Null"
    Bool(b) => "Bool(\{b})"
    Int(n) => "Int(\{n})"
    Int64(n) => "Int64(\{n})"
    Double(d) => "Double(\{d})"
    Text(s) => "Text(\"\{s}\")"
    Blob(b) => "Blob(\{b.length()} bytes)"
  }
}

///|
fn params_str(vals : Array[@moondb.Value]) -> String {
  "[" + vals.map(render).join(", ") + "]"
}

///|
#coverage.skip
fn main {
  println("-- columns derived from fields: " + heroes.column_names().join(", "))
  println("-- create_table_sql")
  println(heroes.create_table_sql())

  // to_columns is derived from the field encoders — insert_of binds every field.
  let (isql, iparams) = heroes
    .insert_of({ id: 1, name: "lfanke", power: 233, })
    .build()
  println("")
  println("-- insert_of (binding derived from field encoders)")
  println(isql)
  println("params: " + params_str(iparams))

  // A single Field carries its own column metadata.
  let email : @moonorm.Field[Hero] = @moonorm.field(
    "email",
    TextType,
    h => @moondb.Text(h.name),
    unique=true,
  )
  println("")
  println("-- Field::name -> \{email.name()}")

  // Round trip: the derived binding stores, the from_row decoder reads back.
  try {
    let sess = @moonorm.Session::new(@moondb.MockDriver::new())
    let roster : Array[Hero] = [
      { id: 1, name: "qwq", power: 66666, },
      { id: 233, name: "emm", power: 23333, },
    ]
    for h in roster {
      sess.insert_record(heroes, h) |> ignore
    }
    println("")
    println("-- round trip via the from_fields model")
    for h in sess.all(heroes) {
      println("  #\{h.id} \{h.name} power=\{h.power}")
    }
    sess.close()
  } catch {
    e => println("db error: " + e.to_string())
  }
}
