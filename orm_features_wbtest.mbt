// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// CTE / subquery builder coverage and the optimistic-lock guard. The builder tests
// assert the emitted SQL and — the point of the whole design — that every value is
// bound as a `?` parameter in left-to-right text order, never spliced. The
// optimistic-lock test drives the guard with a deterministic driver double whose
// affected-row count is configurable, so both the lost-update (0 rows) and the
// success (>=1 row) paths run on every backend without a database.

// --- CTE and subquery in the builder -------------------------------------------

///|
test "builder: WITH renders a leading CTE and its params come first" {
  let recent = select("orders").column("user_id").where_("total", ">", Int(100))
  let (sql, params) = select("users")
    .column("id")
    .column("name")
    .with_cte("big_spenders", recent)
    .where_("active", "=", Bool(true))
    .build()
  assert_eq(
    sql, "WITH big_spenders AS (SELECT user_id FROM orders WHERE total > ?) SELECT id, name FROM users WHERE active = ?",
  )
  // CTE param (100) leads; the outer WHERE param (true) follows — text order.
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Int(100), true)
  assert_eq(params[1] == Bool(true), true)
}

///|
test "builder: WHERE col IN (subquery) binds the subquery's values in place" {
  let team_ids = select("teams").column("id").where_("region", "=", Text("EU"))
  let (sql, params) = select("heroes")
    .where_("active", "=", Bool(true))
    .where_in("team_id", team_ids)
    .build()
  assert_eq(
    sql, "SELECT * FROM heroes WHERE active = ? AND team_id IN (SELECT id FROM teams WHERE region = ?)",
  )
  // Scalar predicate first (true), then the subquery's bound value (\"EU\").
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Bool(true), true)
  assert_eq(params[1] == Text("EU"), true)
}

///|
test "builder: NOT IN subquery and an injection attempt stays a bound value" {
  let evil = "1); DROP TABLE users; --"
  let banned = select("bans").column("user_id").where_("kind", "=", Text(evil))
  let (sql, params) = select("users").where_not_in("id", banned).build()
  assert_eq(
    sql, "SELECT * FROM users WHERE id NOT IN (SELECT user_id FROM bans WHERE kind = ?)",
  )
  // The malicious string never reaches the SQL text; it rides as a bound param.
  assert_eq(params.length(), 1)
  assert_eq(params[0] == Text(evil), true)
  assert_eq(sql.contains("DROP TABLE"), false)
}

///|
test "builder: a CTE combined with a subquery predicate keeps params in text order" {
  let cte_sub = select("a").column("x").where_("p", "=", Int(1))
  let in_sub = select("b").column("y").where_("q", "=", Int(3))
  let (sql, params) = select("t")
    .with_cte("c", cte_sub)
    .where_("r", "=", Int(2))
    .where_in("y", in_sub)
    .build()
  assert_eq(
    sql, "WITH c AS (SELECT x FROM a WHERE p = ?) SELECT * FROM t WHERE r = ? AND y IN (SELECT y FROM b WHERE q = ?)",
  )
  // CTE(1) -> scalar WHERE(2) -> subquery WHERE(3): exactly the SQL text order.
  assert_eq(params.length(), 3)
  assert_eq(params[0] == Int(1), true)
  assert_eq(params[1] == Int(2), true)
  assert_eq(params[2] == Int(3), true)
}

///|
test "builder: WITH RECURSIVE UNION ALL walks a counter and leads with its params" {
  let anchor = select("seed").column("n").where_("n", "=", Int(233))
  let step = select("cnt").column("n + 1").where_("n", "<", Int(66666))
  let (sql, params) = select("cnt")
    .with_recursive("cnt", anchor, step, all=true)
    .column("n")
    .build()
  assert_eq(
    sql, "WITH RECURSIVE cnt AS (SELECT n FROM seed WHERE n = ? UNION ALL SELECT n + 1 FROM cnt WHERE n < ?) SELECT n FROM cnt",
  )
  // Anchor bound value (233) first, recursive term (66666) next — both lead the
  // outer query because the WITH clause leads the SQL text.
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Int(233), true)
  assert_eq(params[1] == Int(66666), true)
}

///|
test "builder: WITH RECURSIVE UNION references the CTE name in the recursive term's JOIN" {
  let roots = select("org")
    .column("id")
    .column("parent_id")
    .where_("parent_id", "=", Null)
  let branch = select("org")
    .column("org.id")
    .column("org.parent_id")
    .join("tree", "org.parent_id = tree.id")
  let (sql, _) = select("tree")
    .with_recursive("tree", roots, branch)
    .column("id")
    .column("parent_id")
    .build()
  assert_eq(
    sql, "WITH RECURSIVE tree AS (SELECT id, parent_id FROM org WHERE parent_id IS NULL UNION SELECT org.id, org.parent_id FROM org JOIN tree ON org.parent_id = tree.id) SELECT id, parent_id FROM tree",
  )
}

// --- Optimistic lock -----------------------------------------------------------

///|
/// A driver double that reports a fixed `affected` count for every `execute` and
/// remembers the last statement it saw. It is not a store; it exists solely to
/// drive `Session::modify_versioned` down both of its branches deterministically.
struct FixedDriver {
  affected : Int64
  mut last_sql : String
  mut last_params : Array[Value]
}

///|
fn FixedDriver::new(affected : Int64) -> FixedDriver {
  { affected, last_sql: "", last_params: [], }
}

///|
pub impl @moondb.Driver for FixedDriver with fn execute(self, sql, params) {
  self.last_sql = sql
  self.last_params = params
  { rows_affected: self.affected, last_insert_id: 0, }
}

///|
pub impl @moondb.Driver for FixedDriver with fn query(_self, _sql, _params) {
  []
}

///|
pub impl @moondb.Driver for FixedDriver with fn begin(_self) -> Unit raise @moondb.DbError {

}

///|
pub impl @moondb.Driver for FixedDriver with fn commit(_self) -> Unit raise @moondb.DbError {

}

///|
pub impl @moondb.Driver for FixedDriver with fn rollback(_self) -> Unit raise @moondb.DbError {

}

///|
pub impl @moondb.Driver for FixedDriver with fn close(_self) -> Unit {

}

///|
/// The versioned UPDATE a caller writes: bump the version, guard on the one it read.
fn versioned_update(current : Int) -> Update {
  update("account")
  .set("balance", Int(50))
  .set("version", Int(current + 1))
  .where_("id", "=", Int(1))
  .where_("version", "=", Int(current))
}

///|
test "optimistic lock: zero rows affected is a LostUpdate" {
  let sess = Session::new(FixedDriver::new(0))
  let caught = try {
    sess.modify_versioned(versioned_update(3), what="account") |> ignore
    false
  } catch {
    LostUpdate(_) => true
    _ => false
  }
  assert_eq(caught, true)
}

///|
test "optimistic lock: a matched row returns the result, no raise" {
  let drv = FixedDriver::new(1)
  let sess = Session::new(drv)
  let res = sess.modify_versioned(versioned_update(3)) catch {
    _ => abort("a matched update must not raise")
  }
  assert_eq(res.rows_affected, 1L)
  // The version guard and the bumped version are both bound, never spliced.
  assert_eq(
    drv.last_sql,
    "UPDATE account SET balance = ?, version = ? WHERE id = ? AND version = ?",
  )
  assert_eq(drv.last_params.length(), 4)
  assert_eq(drv.last_params[1] == Int(4), true) // new version
  assert_eq(drv.last_params[3] == Int(3), true) // expected version
}

///|
pub extend FixedDriver with @moondb.Driver::{
  execute,
  begin,
  ping,
  close,
  query_stream,
  commit,
  query,
  rollback,
}
