///|
/// Row locks on a `SELECT` (SQLAlchemy `with_for_update`): `FOR UPDATE` by default,
/// `FOR SHARE` with `read=true`, restricted to named tables with `of`, and either
/// `NOWAIT` (fail on a locked row) or `SKIP LOCKED` (skip it) — the last being the
/// classic work-queue "claim the next free job" pattern. The clause renders after
/// `ORDER BY` / `LIMIT`, the standard SQL position; SQLite has no row locks and
/// ignores it, PostgreSQL/MySQL honour it.
///
///     moon run examples/09-row-locking
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
  // FOR UPDATE, the default: lock the selected rows for a read-modify-write.
  let (sql, params) = @moonorm.select("accounts")
    .column("id")
    .column("balance")
    .where_("id", "=", @moondb.Int(233))
    .for_update()
    .build()
  println("-- for update")
  println(sql)
  println("params: " + params_str(params))

  // FOR SHARE with NOWAIT: a shared lock that fails rather than waits.
  let (rsql, _) = @moonorm.select("accounts")
    .column("id")
    .where_("owner", "=", @moondb.Text("lfanke"))
    .for_update(read=true, nowait=true)
    .build()
  println("")
  println("-- for share, nowait")
  println(rsql)

  // Restrict the lock to a named table and skip already-locked rows — claim the next
  // free job from a queue without blocking on rows another worker holds.
  let (qsql, _) = @moonorm.select("jobs j")
    .raw("j.id")
    .where_("j.state", "=", @moondb.Text("qwe"))
    .order_by("j.id", Asc)
    .limit(1)
    .for_update(of=["j"], skip_locked=true)
    .build()
  println("")
  println("-- for update of j, skip locked (job-queue claim)")
  println(qsql)
}
