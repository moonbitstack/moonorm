///|
/// A DELETE statement builder. Generative like `Select`, and it shares the same
/// WHERE clause.
pub struct Delete {
  table : String
  filter : Where
  returning : Array[String]
}

///|
/// Start a DELETE from `table`.
pub fn delete(table : String) -> Delete {
  { table, filter: Where::new(), returning: [], }
}

///|
fn Delete::dup(self : Delete) -> Delete {
  {
    table: self.table,
    filter: self.filter.dup(),
    returning: self.returning.copy(),
  }
}

///|
/// Narrow the delete with `col op ?`. Conditions are ANDed together.
pub fn Delete::where_(
  self : Delete,
  col : String,
  op : String,
  val : Value,
) -> Delete {
  let d = self.dup()
  d.filter.conds.push({ col, op, val, })
  d
}

///|
/// Narrow the delete with a boolean `Predicate` tree. See `Select::where_pred`.
pub fn Delete::where_pred(self : Delete, pred : Predicate) -> Delete {
  let d = self.dup()
  d.filter.preds.push(pred)
  d
}

///|
/// Narrow the delete with `col IN (subquery)` — "delete the rows some other query
/// picks out". The subquery's bound values splice in at the predicate's position.
pub fn Delete::where_in(self : Delete, col : String, sub : Select) -> Delete {
  let d = self.dup()
  d.filter.sub_conds.push({ col, op: "IN", sub, })
  d
}

///|
/// Narrow the delete with `col NOT IN (subquery)`. See `where_in`.
pub fn Delete::where_not_in(
  self : Delete,
  col : String,
  sub : Select,
) -> Delete {
  let d = self.dup()
  d.filter.sub_conds.push({ col, op: "NOT IN", sub, })
  d
}

///|
/// Return `col` from each deleted row (SQLite 3.35+, PostgreSQL) — the row's
/// contents survive the delete only if you ask for them here. Repeatable;
/// `build_for(Mysql)` drops it.
pub fn Delete::returning(self : Delete, col : String) -> Delete {
  let d = self.dup()
  d.returning.push(col)
  d
}

///|
/// Return every column of each deleted row (`RETURNING *`). See `returning`.
pub fn Delete::returning_all(self : Delete) -> Delete {
  self.returning("*")
}

///|
/// Render `(sql, params)` for the SQLite/PostgreSQL dialect.
pub fn Delete::build(self : Delete) -> (String, Array[Value]) {
  self.build_for(Sqlite)
}

///|
/// Render `(sql, params)` for `dialect`. Identical everywhere but `RETURNING`,
/// which MySQL does not have and so does not get.
pub fn Delete::build_for(
  self : Delete,
  dialect : Dialect,
) -> (String, Array[Value]) {
  let params : Array[Value] = []
  let mut sql = "DELETE FROM " + self.table
  let where_sql = self.filter.sql(params)
  if where_sql != "" {
    sql = sql + " WHERE " + where_sql
  }
  if self.returning.length() > 0 && dialect != Mysql {
    sql = sql + " RETURNING " + self.returning.join(", ")
  }
  (sql, params)
}

///|
pub extend LockMode with Debug::{to_repr}

///|
pub extend LockMode with Eq::{not_equal, equal}

///|
pub extend LockClause with Debug::{to_repr}

///|
pub extend LockClause with Eq::{not_equal, equal}
