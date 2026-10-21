///|
/// The `INSERT` builder end to end: a single-row insert with `RETURNING`, a multi-row
/// insert (`values`), and upserts — `on_conflict` with `do_update` / `do_update_excluded`
/// / `do_nothing`, plus `returning_all`. The same builder renders per dialect: `build`
/// (SQLite/PostgreSQL) emits `ON CONFLICT ... DO UPDATE` and keeps `RETURNING`, while
/// `build_for(Mysql)` emits `ON DUPLICATE KEY UPDATE` and drops `RETURNING`. Every value
/// binds as `?`, so a bulk insert or an upsert is injection-safe.
///
///     moon run examples/07-insert-upsert
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
  // Plain insert, returning the server-assigned id in the same round trip.
  let (sql, params) = @moonorm.insert("heroes")
    .set("name", @moondb.Text("lfanke"))
    .set("age", @moondb.Int(233))
    .returning("id")
    .build()
  println("-- insert + returning")
  println(sql)
  println("params: " + params_str(params))

  // Multi-row insert: the first row from `set`, the rest from `values` in the same
  // column order. Each value is its own placeholder.
  let (msql, mparams) = @moonorm.insert("heroes")
    .set("name", @moondb.Text("emm"))
    .set("age", @moondb.Int(23333))
    .values([@moondb.Text("qwq"), @moondb.Int(66666)])
    .values([@moondb.Text("hhh"), @moondb.Int(233)])
    .build()
  println("")
  println("-- multi-row insert")
  println(msql)
  println("params: " + params_str(mparams))

  // Upsert overwriting with the incoming row (`excluded.name`), returning every
  // column. One builder, two dialects.
  let upsert = fn() {
    @moonorm.insert("heroes")
    .set("id", @moondb.Int(1))
    .set("name", @moondb.Text("heke1228"))
    .on_conflict(["id"])
    .do_update_excluded("name")
    .returning_all()
  }
  let (ssql, sparams) = upsert().build()
  println("")
  println("-- upsert (SQLite/PostgreSQL): do_update_excluded + returning_all")
  println(ssql)
  println("params: " + params_str(sparams))
  let (ysql, yparams) = upsert().build_for(Mysql)
  println("")
  println("-- upsert (MySQL): ON DUPLICATE KEY UPDATE, RETURNING dropped")
  println(ysql)
  println("params: " + params_str(yparams))

  // Upsert with a bound update value — the counter increment pattern.
  let (bsql, bparams) = @moonorm.insert("counters")
    .set("key", @moondb.Text("qwe"))
    .set("hits", @moondb.Int(1))
    .on_conflict(["key"])
    .do_update("hits", @moondb.Int(23333))
    .build()
  println("")
  println("-- upsert: do_update bound value")
  println(bsql)
  println("params: " + params_str(bparams))

  // DO NOTHING keeps the existing row; MySQL has no such form, so it renders a
  // no-op self-assignment instead.
  let nothing = fn() {
    @moonorm.insert("seen")
    .set("id", @moondb.Int(233))
    .on_conflict(["id"])
    .do_nothing()
  }
  let (dsql, _) = nothing().build()
  let (dmsql, _) = nothing().build_for(Mysql)
  println("")
  println("-- do_nothing: SQLite/PostgreSQL")
  println(dsql)
  println("-- do_nothing: MySQL no-op self-assign")
  println(dmsql)
}
