///|
/// Optimistic concurrency control: `Session::modify_versioned` runs a version-guarded
/// `UPDATE` and raises `LostUpdate` when it matches no row — the row's version moved
/// on since it was read (SQLAlchemy's `version_id_col` / `StaleDataError`). The new
/// values and the version guard both bind as `?`, so the whole check stays
/// injection-safe. The success path runs over `@moondb.MockDriver`; the lost-update
/// path over a tiny driver that reports zero rows changed.
///
///     moon run examples/17-optimistic-lock
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
/// A driver whose statements always change zero rows — the condition an optimistic
/// `UPDATE` reads as "someone else won the race".
struct Stale {
  affected : Int64
}

///|
impl @moondb.Driver for Stale with fn execute(
  self : Stale,
  _sql : String,
  _params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  { rows_affected: self.affected, last_insert_id: 0L, }
}

///|
impl @moondb.Driver for Stale with fn query(
  _self : Stale,
  _sql : String,
  _params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  []
}

///|
impl @moondb.Driver for Stale with fn begin(_self : Stale) -> Unit raise @moondb.DbError {

}

///|
impl @moondb.Driver for Stale with fn commit(_self : Stale) -> Unit raise @moondb.DbError {

}

///|
impl @moondb.Driver for Stale with fn rollback(_self : Stale) -> Unit raise @moondb.DbError {

}

///|
impl @moondb.Driver for Stale with fn close(_self : Stale) -> Unit {

}

///|
#coverage.skip
fn main {
  // Bump the version in SET, guard the expected version in WHERE.
  let stmt = fn() {
    @moonorm.update("heroes")
    .set("power", @moondb.Int(23333))
    .set("version", @moondb.Int(2))
    .where_("id", "=", @moondb.Int(233))
    .where_("version", "=", @moondb.Int(1))
  }
  let (sql, params) = stmt().build()
  println("-- versioned update")
  println(sql)
  println("params: " + params_str(params))

  // Success: a row matched the expected version, so the guarded write lands.
  try {
    let sess = @moonorm.Session::new(@moondb.MockDriver::new())
    let res = sess.modify_versioned(stmt(), what="hero")
    println("")
    println("-- modify_versioned ok: rows_affected \{res.rows_affected}")
    sess.close()
  } catch {
    e => println("unexpected: \{e}")
  }

  // Lost update: no row matched the expected version -> LostUpdate, not a silent no-op.
  let sess2 = @moonorm.Session::new(Stale::{ affected: 0L, })
  try {
    sess2.modify_versioned(stmt(), what="hero") |> ignore
    println("-- unexpected: stale write succeeded")
  } catch {
    @session.LostUpdate(msg) => println("-- LostUpdate raised: " + msg)
    e => println("-- other error: \{e}")
  }
  sess2.close()
}
