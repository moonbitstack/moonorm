///|
/// A self-referential `categories` tree, walked with a recursive CTE. It declares a
/// `Model`, emits a filtered `SELECT` and a `WITH RECURSIVE` subtree walk — SQL text
/// plus the bound params, never spliced — then drives the same builders through a
/// `Session` over `@moondb.MockDriver`, which needs no database and compiles on every
/// backend.
///
///     moon run examples/00-recursive-cte
struct Category {
  id : Int
  name : String
  parent : Int
}

///|
let categories : @moonorm.Model[Category] = @moonorm.Model::new(
  "categories",
  [
    @moonorm.column("id", @moonorm.IntType, primary_key=true),
    @moonorm.column("name", @moonorm.TextType, nullable=false),
    @moonorm.column(
      "parent_id",
      @moonorm.IntType,
      references=("categories", "id"),
    ),
  ],
  r => { id: r.int(0), name: r.text(1), parent: r.int(2), },
  c => {
    [
      ("id", @moondb.Int(c.id)),
      ("name", @moondb.Text(c.name)),
      ("parent_id", @moondb.Int(c.parent)),
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
  let mut s = "["
  for i, v in vals {
    if i > 0 {
      s = s + ", "
    }
    s = s + render(v)
  }
  s + "]"
}

///|
#coverage.skip
fn main {
  let (sql, params) = categories
    .select()
    .where_("parent_id", ">", @moondb.Int(0))
    .order_by("name", @moonorm.Asc)
    .limit(233)
    .build()
  println("-- filtered select")
  println(sql)
  println("params: " + params_str(params))
  let anchor = @moonorm.select("categories")
    .column("id")
    .column("name")
    .column("parent_id")
    .where_("id", "=", @moondb.Int(1))
  let step = @moonorm.select("categories c")
    .raw("c.id")
    .raw("c.name")
    .raw("c.parent_id")
    .join("subtree s", "c.parent_id = s.id")
  let (rsql, rparams) = @moonorm.select("subtree")
    .column("id")
    .column("name")
    .with_recursive("subtree", anchor, step, all=true)
    .order_by("name", @moonorm.Asc)
    .limit(23333)
    .build()
  println("")
  println("-- recursive subtree walk")
  println(rsql)
  println("params: " + params_str(rparams))
  let tree : Array[Category] = [
    { id: 1, name: "lfanke", parent: 0, },
    { id: 233, name: "heke1228", parent: 1, },
    { id: 23333, name: "qwq", parent: 233, },
    { id: 66666, name: "emm", parent: 233, },
  ]
  println("")
  println("-- through a Session over @moondb.MockDriver")
  try {
    let sess = @moonorm.Session::new(@moondb.MockDriver::new())
    for c in tree {
      sess.insert_record(categories, c) |> ignore
    }
    let loaded = sess.all(categories)
    println("stored \{loaded.length()} rows:")
    for c in loaded {
      println("  #\{c.id} \{c.name} <- parent \{c.parent}")
    }
    sess.close()
  } catch {
    e => println("db error: " + e.to_string())
  }
}
