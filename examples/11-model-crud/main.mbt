///|
/// The declarative `Model` as the CRUD unit: `create_table_sql`, `column_names`,
/// `table_descriptor`, `insert_of` (record -> bound `Insert`), and `Model::select`
/// (every column projected in a fixed order `from_row` expects). Then a full round trip
/// through a `Session` over `@moondb.MockDriver` — `create_table`, `insert_record`,
/// `all`, `fetch_as` — decoding stored rows back into records via the model's mapping.
///
///     moon run examples/11-model-crud
struct Hero {
  id : Int32
  name : String
  power : Int32
}

///|
let heroes : @moonorm.Model[Hero] = @moonorm.Model::new(
  "heroes",
  [
    @moonorm.column("id", IntType, primary_key=true),
    @moonorm.column("name", TextType, nullable=false),
    @moonorm.column("power", IntType),
  ],
  r => { id: r.int(0), name: r.text(1), power: r.int(2), },
  h => {
    [
      ("id", @moondb.Int(h.id)),
      ("name", @moondb.Text(h.name)),
      ("power", @moondb.Int(h.power)),
    ]
  },
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
  println("-- create_table_sql")
  println(heroes.create_table_sql(if_not_exists=true))
  println("-- column_names: " + heroes.column_names().join(", "))
  let td = heroes.table_descriptor()
  println("-- table_descriptor: \{td.name} (" + td.columns.join(", ") + ")")

  // insert_of turns a record into an Insert; values bind as placeholders.
  let (isql, iparams) = heroes
    .insert_of({ id: 1, name: "lfanke", power: 233, })
    .build()
  println("")
  println("-- insert_of")
  println(isql)
  println("params: " + params_str(iparams))

  // Model::select projects every declared column, refinable like any Select.
  let (ssql, sparams) = heroes
    .select()
    .where_("power", ">", @moondb.Int(100))
    .build()
  println("")
  println("-- Model::select refined")
  println(ssql)
  println("params: " + params_str(sparams))

  // create_table issues the DDL; over MockDriver it returns a one-row ExecResult.
  try {
    let drv = @moondb.MockDriver::new()
    let sess = @moonorm.Session::new(drv)
    let ddl = sess.create_table(heroes, if_not_exists=true)
    println("")
    println("-- Session.create_table rows_affected=\{ddl.rows_affected}")
    sess.close()
  } catch {
    e => println("db error: " + e.to_string())
  }

  // A clean session for the round trip (MockDriver echoes every stored row, so keep
  // the DDL echo out of the read-back store).
  try {
    let drv = @moondb.MockDriver::new()
    let sess = @moonorm.Session::new(drv)
    let roster : Array[Hero] = [
      { id: 1, name: "lfanke", power: 233, },
      { id: 233, name: "heke1228", power: 23333, },
      { id: 66666, name: "qwq", power: 66666, },
    ]
    for h in roster {
      sess.insert_record(heroes, h) |> ignore
    }
    println("")
    println("-- Session.all (decoded records)")
    for h in sess.all(heroes) {
      println("  #\{h.id} \{h.name} power=\{h.power}")
    }
    let some = sess.fetch_as(heroes, heroes.select())
    println("-- fetch_as returned \{some.length()} records")
    // fetch returns raw rows (undecoded) for the same Select.
    let raw = sess.fetch(heroes.select())
    println(
      "-- fetch returned \{raw.length()} raw rows, first width=\{raw[0].width()}",
    )
    sess.close()
  } catch {
    e => println("db error: " + e.to_string())
  }
}
