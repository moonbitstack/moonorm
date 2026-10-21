///|
/// What one `SET` assigns: a bound value (`col = ?`), or an expression rendered
/// verbatim with its own placeholders, which is the only way to write a column in
/// terms of itself (`n = n + ?`).
enum Assign {
  Bind(Value)
  Expr(String, Array[Value])
}

///|
/// An UPDATE statement builder. Generative like `Select`, and it shares the same
/// WHERE clause, so `where_pred` / `where_in` narrow an update exactly as they
/// narrow a query.
pub struct Update {
  table : String
  sets : Array[(String, Assign)]
  filter : Where
  returning : Array[String]
}

///|
/// Start an UPDATE of `table`. Without a `where_` it rewrites every row, which
/// is what SQL does and what the caller asked for.
pub fn update(table : String) -> Update {
  { table, sets: [], filter: Where::new(), returning: [], }
}

///|
fn Update::dup(self : Update) -> Update {
  {
    table: self.table,
    sets: self.sets.copy(),
    filter: self.filter.dup(),
    returning: self.returning.copy(),
  }
}

///|
/// Assign one column a bound value. Repeated calls set each, in the order given.
pub fn Update::set(self : Update, col : String, val : Value) -> Update {
  let u = self.dup()
  u.sets.push((col, Bind(val)))
  u
}

///|
/// Assign one column an expression instead of a value — `set_expr("n", "n + ?",
/// vals=[Int(1)])` renders `SET n = n + ?`. The expression is rendered verbatim, so
/// it can read the row's current columns, which a bound value cannot; anything that
/// varies belongs in `vals`, one per `?`, and binds in the order the placeholders
/// appear.
pub fn Update::set_expr(
  self : Update,
  col : String,
  expr : String,
  vals~ : Array[Value] = [],
) -> Update {
  let u = self.dup()
  u.sets.push((col, Expr(expr, vals)))
  u
}

///|
/// Narrow the update with `col op ?`. Conditions are ANDed together.
pub fn Update::where_(
  self : Update,
  col : String,
  op : String,
  val : Value,
) -> Update {
  let u = self.dup()
  u.filter.conds.push({ col, op, val, })
  u
}

///|
/// Narrow the update with a boolean `Predicate` tree — the `AND`/`OR`/`NOT`
/// grouping the flat `where_` cannot express. See `Select::where_pred`.
pub fn Update::where_pred(self : Update, pred : Predicate) -> Update {
  let u = self.dup()
  u.filter.preds.push(pred)
  u
}

///|
/// Narrow the update with `col IN (subquery)` — "update the rows some other query
/// picks out". The subquery's bound values splice in at the predicate's position.
pub fn Update::where_in(self : Update, col : String, sub : Select) -> Update {
  let u = self.dup()
  u.filter.sub_conds.push({ col, op: "IN", sub, })
  u
}

///|
/// Narrow the update with `col NOT IN (subquery)`. See `where_in`.
pub fn Update::where_not_in(
  self : Update,
  col : String,
  sub : Select,
) -> Update {
  let u = self.dup()
  u.filter.sub_conds.push({ col, op: "NOT IN", sub, })
  u
}

///|
/// Return `col` from each updated row (SQLite 3.35+, PostgreSQL). Repeatable;
/// `build_for(Mysql)` drops it.
pub fn Update::returning(self : Update, col : String) -> Update {
  let u = self.dup()
  u.returning.push(col)
  u
}

///|
/// Return every column of each updated row (`RETURNING *`). See `returning`.
pub fn Update::returning_all(self : Update) -> Update {
  self.returning("*")
}

///|
/// Render `(sql, params)` for the SQLite/PostgreSQL dialect. The SET values come
/// first and the WHERE values after, in the order the placeholders appear, which is
/// the order every driver binds in.
pub fn Update::build(self : Update) -> (String, Array[Value]) {
  self.build_for(Sqlite)
}

///|
/// Render `(sql, params)` for `dialect`. Identical everywhere but `RETURNING`,
/// which MySQL does not have and so does not get.
pub fn Update::build_for(
  self : Update,
  dialect : Dialect,
) -> (String, Array[Value]) {
  let params : Array[Value] = []
  let setparts : Array[String] = []
  for pair in self.sets {
    let (col, assign) = pair
    match assign {
      Bind(v) => {
        setparts.push(col + " = ?")
        params.push(v)
      }
      Expr(expr, vals) => {
        setparts.push(col + " = " + expr)
        for v in vals {
          params.push(v)
        }
      }
    }
  }
  let mut sql = "UPDATE " + self.table + " SET " + setparts.join(", ")
  let where_sql = self.filter.sql(params)
  if where_sql != "" {
    sql = sql + " WHERE " + where_sql
  }
  if self.returning.length() > 0 && dialect != Mysql {
    sql = sql + " RETURNING " + self.returning.join(", ")
  }
  (sql, params)
}
