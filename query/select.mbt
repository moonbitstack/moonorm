///|
/// A SELECT statement builder. Every method is generative — it returns a new
/// statement and leaves the receiver alone — so a half-built query is a safe base to
/// branch from, which is what SQLAlchemy's statement API guarantees.
pub struct Select {
  from_ : Source
  ctes : Array[Cte]
  cols : Array[String]
  joins : Array[JoinClause]
  filter : Where
  groups : Array[String]
  havings : Array[Cond]
  orders : Array[OrderTerm]
  // Set operations chained onto this query: (keyword, operand). The compound's
  // ORDER BY / LIMIT come from this outer `Select`, applying to the whole result.
  set_ops : Array[(String, Select)]
  distinct_on_ : Array[String]
  mut distinct_ : Bool
  mut limit_ : Int32?
  mut offset_ : Int32?
  // Row-locking clause (SQLAlchemy `.with_for_update()`); `None` = no locking.
  mut lock_ : LockClause?
}

///|
/// The kind of row lock a `FOR UPDATE` / `FOR SHARE` clause takes.
pub(all) enum LockMode {
  ForUpdate
  ForShare
} derive(Eq, Debug)

///|
/// A row-locking clause on a `SELECT` (SQLAlchemy `with_for_update`): the lock
/// `mode`, the tables it is restricted to (`OF …`, empty = all), and whether it
/// fails rather than waits (`NOWAIT`) or skips locked rows (`SKIP LOCKED`).
pub(all) struct LockClause {
  mode : LockMode
  of : Array[String]
  nowait : Bool
  skip_locked : Bool
} derive(Eq, Debug)

///|
/// Start a SELECT over `src` — a table name, or a `Source` for a derived table,
/// an alias or a LATERAL.
pub fn[S : AsSource] select(src : S) -> Select {
  {
    from_: src.to_source(),
    ctes: [],
    cols: [],
    joins: [],
    filter: Where::new(),
    groups: [],
    havings: [],
    orders: [],
    set_ops: [],
    distinct_on_: [],
    distinct_: false,
    limit_: None,
    offset_: None,
    lock_: None,
  }
}

///|
/// The copy every builder method starts from: the arrays are cloned so the new
/// statement can be extended without the receiver seeing it, while the `Select`s
/// nested inside (subqueries, CTEs, compound operands) are shared, which is safe
/// precisely because nothing is ever mutated in place.
fn Select::dup(self : Select) -> Select {
  {
    from_: self.from_,
    ctes: self.ctes.copy(),
    cols: self.cols.copy(),
    joins: self.joins.copy(),
    filter: self.filter.dup(),
    groups: self.groups.copy(),
    havings: self.havings.copy(),
    orders: self.orders.copy(),
    set_ops: self.set_ops.copy(),
    distinct_on_: self.distinct_on_.copy(),
    distinct_: self.distinct_,
    limit_: self.limit_,
    offset_: self.offset_,
    lock_: self.lock_,
  }
}

///|
/// Take a row lock on the selected rows (SQLAlchemy `Select.with_for_update`): `FOR UPDATE` by
/// default, or `FOR SHARE` when `read`; restrict it to certain tables with `of`; make it fail
/// immediately on a locked row with `nowait`, or skip locked rows with `skip_locked`. The clause is
/// emitted after `ORDER BY` / `LIMIT` / `OFFSET`, the standard SQL position (SQLite, which has no
/// row locks, ignores it).
pub fn Select::for_update(
  self : Select,
  read~ : Bool = false,
  of~ : Array[String] = [],
  nowait~ : Bool = false,
  skip_locked~ : Bool = false,
) -> Select {
  let s = self.dup()
  s.lock_ = Some({
    mode: if read {
      ForShare
    } else {
      ForUpdate
    },
    of,
    nowait,
    skip_locked,
  })
  s
}

///|
/// Deduplicate the result set: `SELECT DISTINCT`. Applies to this query's own
/// projection (each operand of a set operation carries its own DISTINCT).
pub fn Select::distinct(self : Select) -> Select {
  let s = self.dup()
  s.distinct_ = true
  s
}

///|
/// Keep the first row of each distinct `cols` group: `SELECT DISTINCT ON (a, b)`,
/// PostgreSQL's extension. Which row is "first" is whatever `ORDER BY` says, so pair
/// it with an `order_by` that leads with the same columns. Takes precedence over
/// plain `distinct` when both are set; no other dialect accepts it.
pub fn Select::distinct_on(self : Select, cols : Array[String]) -> Select {
  let s = self.dup()
  for c in cols {
    s.distinct_on_.push(c)
  }
  s
}

///|
/// `UNION` this query with `other` — the combined rows with duplicates removed. A
/// trailing ORDER BY / LIMIT on this query binds to the whole compound (standard
/// SQL); one on `other` makes it a derived table so it keeps binding to `other`.
pub fn Select::union(self : Select, other : Select) -> Select {
  self.set_op("UNION", other)
}

///|
/// `UNION ALL` — the combined rows keeping duplicates.
pub fn Select::union_all(self : Select, other : Select) -> Select {
  self.set_op("UNION ALL", other)
}

///|
/// `INTERSECT` — rows present in both queries.
pub fn Select::intersect(self : Select, other : Select) -> Select {
  self.set_op("INTERSECT", other)
}

///|
/// `EXCEPT` — rows in this query but not in `other` (SQL's set difference).
pub fn Select::except_(self : Select, other : Select) -> Select {
  self.set_op("EXCEPT", other)
}

///|
fn Select::set_op(self : Select, op : String, other : Select) -> Select {
  let s = self.dup()
  s.set_ops.push((op, other))
  s
}

///|
/// Add a projected column (no columns selects `*`).
pub fn Select::column(self : Select, col : String) -> Select {
  let s = self.dup()
  s.cols.push(col)
  s
}

///|
/// Add a raw column expression (e.g. an aggregate like `"SUM(price)"` or a
/// qualified `"users.id"`). Identical machinery to `column`; named for intent so
/// call sites read as "this is an expression, not a plain column name".
pub fn Select::raw(self : Select, expr : String) -> Select {
  let s = self.dup()
  s.cols.push(expr)
  s
}

///|
/// Project an expression under a name: `expr AS name` (SQLAlchemy's `.label()`).
/// The name is what the result row is keyed by, so it is what `from_row` reads.
pub fn Select::label(self : Select, expr : String, name : String) -> Select {
  self.raw(expr + " AS " + name)
}

///|
/// Project `COUNT(*)` — the most common aggregate. Sugar for `raw("COUNT(*)")`.
pub fn Select::count(self : Select) -> Select {
  self.raw("COUNT(*)")
}

///|
/// Project a window function: `<expr> OVER (PARTITION BY … ORDER BY …)`, optionally
/// aliased. Window functions compute over a frame of rows without collapsing them
/// (`ROW_NUMBER()`, `RANK()`, a running `SUM(x)`), so this adds one more projected
/// column rather than grouping. `expr` is the function call (`"ROW_NUMBER()"`,
/// `"SUM(amount)"`), `partition_by` splits the rows into independent windows, and
/// `order_by` ranks within each. All three are identifier-level SQL (they name
/// columns and functions, never bound values), so they render verbatim like `raw`
/// and carry no parameters. An empty `partition_by` and `order_by` yields the whole
/// result as one unordered window, `<expr> OVER ()`.
pub fn Select::window(
  self : Select,
  expr : String,
  partition_by~ : Array[String] = [],
  order_by~ : Array[(String, Order)] = [],
  as_~ : String = "",
) -> Select {
  let inner : Array[String] = []
  if partition_by.length() > 0 {
    inner.push("PARTITION BY " + partition_by.join(", "))
  }
  if order_by.length() > 0 {
    let oparts : Array[String] = []
    for o in order_by {
      oparts.push(o.0 + " " + order_sql(o.1))
    }
    inner.push("ORDER BY " + oparts.join(", "))
  }
  let over = expr + " OVER (" + inner.join(" ") + ")"
  self.raw(if as_ == "" { over } else { over + " AS " + as_ })
}

///|
fn Select::add_join(
  self : Select,
  kind : String,
  src : Source,
  on : String,
  using_ : Array[String],
) -> Select {
  let s = self.dup()
  s.joins.push({ kind, src, on, using_, })
  s
}

///|
/// Add an inner `JOIN src ON <on>`. `src` is a table name or a `Source` (a derived
/// table brings its bound values with it). The `on` predicate is rendered verbatim
/// (it references columns, not bound values), so pass only trusted identifiers.
pub fn[S : AsSource] Select::join(
  self : Select,
  src : S,
  on : String,
) -> Select {
  self.add_join("JOIN", src.to_source(), on, [])
}

///|
/// Add a `LEFT JOIN src ON <on>` — every left row, matched or not. See `join`.
pub fn[S : AsSource] Select::left_join(
  self : Select,
  src : S,
  on : String,
) -> Select {
  self.add_join("LEFT JOIN", src.to_source(), on, [])
}

///|
/// Add a `RIGHT JOIN src ON <on>` — every right row, matched or not. See `join`.
/// SQLite gained it in 3.39; older versions need the join written the other way.
pub fn[S : AsSource] Select::right_join(
  self : Select,
  src : S,
  on : String,
) -> Select {
  self.add_join("RIGHT JOIN", src.to_source(), on, [])
}

///|
/// Add a `FULL JOIN src ON <on>` — every row of both sides. See `join`. MySQL has
/// no FULL JOIN; SQLite gained it in 3.39.
pub fn[S : AsSource] Select::full_join(
  self : Select,
  src : S,
  on : String,
) -> Select {
  self.add_join("FULL JOIN", src.to_source(), on, [])
}

///|
/// Add a `CROSS JOIN src` — the cartesian product, which takes no `ON`. Paired with
/// a `Lateral` source this is how a row-generating function is joined per row.
pub fn[S : AsSource] Select::cross_join(self : Select, src : S) -> Select {
  self.add_join("CROSS JOIN", src.to_source(), "", [])
}

///|
/// Add a `JOIN src USING (a, b)` — the equi-join on columns of the same name in
/// both tables, which also collapses each pair into one output column. `cols` are
/// identifiers, rendered verbatim.
pub fn[S : AsSource] Select::join_using(
  self : Select,
  src : S,
  cols : Array[String],
) -> Select {
  self.add_join("JOIN", src.to_source(), "", cols)
}

///|
/// Add a `GROUP BY` column (repeatable; columns are emitted in call order).
pub fn Select::group_by(self : Select, col : String) -> Select {
  let s = self.dup()
  s.groups.push(col)
  s
}

///|
/// Add a `col op ?` predicate to the `HAVING` clause (ANDed with the rest). The
/// value is bound as a `?` placeholder exactly like `where_`, so aggregate
/// filters stay injection-safe.
pub fn Select::having(
  self : Select,
  col : String,
  op : String,
  val : Value,
) -> Select {
  let s = self.dup()
  s.havings.push({ col, op, val, })
  s
}

///|
/// Add a `col op ?` predicate (ANDed with the rest).
pub fn Select::where_(
  self : Select,
  col : String,
  op : String,
  val : Value,
) -> Select {
  let s = self.dup()
  s.filter.conds.push({ col, op, val, })
  s
}

///|
/// Shorthand for `where_(col, "=", val)`.
pub fn Select::eq(self : Select, col : String, val : Value) -> Select {
  self.where_(col, "=", val)
}

///|
/// Add a boolean `Predicate` tree to the `WHERE` — the parameter-safe `AND`/`OR`/`NOT`
/// grouping the flat `where_`/`eq` cannot express, e.g.
/// `where_pred(Or([Cmp(col="a", op="=", val=Int(1)), Cmp(col="b", op="=", val=Int(2))]))`.
/// Predicates are ANDed with the other clauses, so mixing `eq(...)` and `where_pred(...)`
/// composes as one conjunction.
pub fn Select::where_pred(self : Select, pred : Predicate) -> Select {
  let s = self.dup()
  s.filter.preds.push(pred)
  s
}

///|
/// Attach a common table expression: `WITH name AS (sub)`. Repeatable — several
/// CTEs render comma-separated in one leading `WITH`. The subquery is parameterised
/// like any other statement; its bound values lead the final params list because
/// the `WITH` clause leads the SQL text. `name` is a trusted identifier declared in
/// code, never a bound value.
pub fn Select::with_cte(self : Select, name : String, sub : Select) -> Select {
  let s = self.dup()
  s.ctes.push({ name, sub, recursive: false, })
  s
}

///|
/// Attach a recursive common table expression (SQLAlchemy's `select(...).cte(recursive=True)`):
/// `WITH RECURSIVE name AS (anchor UNION [ALL] step)`. `anchor` is the base term and `step`
/// the term that refers back to `name` in its own `FROM` — the CTE name is a trusted identifier
/// referenceable in `step` and in this query's own `FROM`, so the usual shape is
/// `select(name).with_recursive(name, anchor, step)`. `all` picks `UNION ALL` (keep duplicates,
/// the common tree/graph walk) over the default `UNION`. The two terms compose through the existing
/// `union` / `union_all` builders, so their bound values thread through in text order like any CTE.
pub fn Select::with_recursive(
  self : Select,
  name : String,
  anchor : Select,
  step : Select,
  all~ : Bool = false,
) -> Select {
  let sub = if all { anchor.union_all(step) } else { anchor.union(step) }
  let s = self.dup()
  s.ctes.push({ name, sub, recursive: true, })
  s
}

///|
/// Add a `col IN (subquery)` predicate (ANDed with the rest). The subquery's bound
/// values splice in at the predicate's position, so a correlated or filtering
/// subquery stays injection-safe exactly like a scalar `where_`.
pub fn Select::where_in(self : Select, col : String, sub : Select) -> Select {
  let s = self.dup()
  s.filter.sub_conds.push({ col, op: "IN", sub, })
  s
}

///|
/// Add a `col NOT IN (subquery)` predicate (ANDed with the rest). See `where_in`.
pub fn Select::where_not_in(
  self : Select,
  col : String,
  sub : Select,
) -> Select {
  let s = self.dup()
  s.filter.sub_conds.push({ col, op: "NOT IN", sub, })
  s
}

///|
/// Add an `EXISTS (subquery)` predicate (ANDed with the rest) — true when the
/// subquery returns any row (SQLAlchemy's `exists()`). The subquery's bound values
/// splice in at its position, so it stays injection-safe.
pub fn Select::where_exists(self : Select, sub : Select) -> Select {
  self.where_pred(Exists(sub~, negated=false))
}

///|
/// Add a `NOT EXISTS (subquery)` predicate (ANDed with the rest). See `where_exists`.
pub fn Select::where_not_exists(self : Select, sub : Select) -> Select {
  self.where_pred(Exists(sub~, negated=true))
}

///|
/// Add a `col IN (?, ?, …)` predicate over an explicit list of values (ANDed with
/// the rest). Every value binds as its own placeholder, never spliced — this is the
/// set-membership filter a batch load issues to fetch the related rows of many
/// parents in one round trip (`WHERE fk IN (key1, key2, …)`) instead of one query
/// per parent. An empty `vals` renders the always-false `1 = 0` — "in the empty set"
/// matches nothing — so a batch load with no keys returns no rows rather than erroring.
pub fn Select::where_in_values(
  self : Select,
  col : String,
  vals : Array[Value],
) -> Select {
  let s = self.dup()
  s.filter.in_conds.push({ col, negated: false, vals, })
  s
}

///|
/// Add a `col NOT IN (?, ?, …)` predicate over an explicit list of values (ANDed
/// with the rest). See `where_in_values`; an empty `vals` renders the always-true
/// `1 = 1` — "not in the empty set" matches every row.
pub fn Select::where_not_in_values(
  self : Select,
  col : String,
  vals : Array[Value],
) -> Select {
  let s = self.dup()
  s.filter.in_conds.push({ col, negated: true, vals, })
  s
}

///|
/// Order the result by a column. Repeated calls order by each in turn. `nulls`
/// places NULLs explicitly (`NULLS FIRST` / `NULLS LAST`); the default leaves it to
/// the server, which is the only portable choice — MySQL rejects the syntax.
pub fn Select::order_by(
  self : Select,
  col : String,
  ord : Order,
  nulls~ : Nulls = Auto,
) -> Select {
  let s = self.dup()
  s.orders.push({ col, ord, nulls, })
  s
}

///|
/// Cap how many rows come back.
pub fn Select::limit(self : Select, n : Int32) -> Select {
  let s = self.dup()
  s.limit_ = Some(n)
  s
}

///|
/// Skip the first `n` rows. Paired with `limit` this is a page.
pub fn Select::offset(self : Select, n : Int32) -> Select {
  let s = self.dup()
  s.offset_ = Some(n)
  s
}

///|
/// The alias given to a compound operand that has to become a derived table. It is
/// the only name in that FROM, so one fixed name never collides.
const COMPOUND_ALIAS : String = "_c"

///|
/// Wrap a rendered statement as a derived table. This is how a compound operand is
/// grouped: parenthesising the operand is standard SQL but SQLite rejects it
/// outright, while `SELECT * FROM (…) AS _c` is read the same way everywhere.
fn derived(sql : String) -> String {
  "SELECT * FROM (" + sql + ") AS " + COMPOUND_ALIAS
}

///|
/// How tightly a set operator binds. The standard gives INTERSECT the higher
/// precedence; SQLite instead groups every operator left to right, so a chain that
/// mixes the two levels means different things on different servers unless the
/// grouping is made explicit.
fn set_prec(op : String) -> Int32 {
  if op == "INTERSECT" {
    2
  } else {
    1
  }
}

///|
/// Whether this query can stand as a compound operand as-is. A nested compound, a
/// leading `WITH`, or a trailing `ORDER BY` / `LIMIT` / `OFFSET` / `FOR UPDATE`
/// would otherwise re-bind to the enclosing compound rather than to this operand.
fn Select::is_atom(self : Select) -> Bool {
  self.set_ops.length() == 0 &&
  self.ctes.length() == 0 &&
  self.orders.length() == 0 &&
  self.limit_ is None &&
  self.offset_ is None &&
  self.lock_ is None
}

///|
/// Render to `(sql, params)`, with `?` placeholders for every bound value. Bound
/// values appear in the params list in the same left-to-right order they occur in
/// the SQL text: CTE subqueries first (the leading `WITH`), then any derived table
/// in `FROM` and the joins, then the `WHERE` predicates, then `HAVING`, then the
/// set-operation operands.
pub fn Select::build(self : Select) -> (String, Array[Value]) {
  let params : Array[Value] = []
  let mut sql = ""
  if self.ctes.length() > 0 {
    let cte_parts : Array[String] = []
    let mut recursive = false
    for cte in self.ctes {
      recursive = recursive || cte.recursive
      let (sub_sql, sub_params) = cte.sub.build()
      cte_parts.push(cte.name + " AS (" + sub_sql + ")")
      for p in sub_params {
        params.push(p)
      }
    }
    sql = "WITH " +
      (if recursive { "RECURSIVE " } else { "" }) +
      cte_parts.join(", ") +
      " "
  }
  let head = if self.distinct_on_.length() > 0 {
    "DISTINCT ON (" + self.distinct_on_.join(", ") + ") "
  } else if self.distinct_ {
    "DISTINCT "
  } else {
    ""
  }
  sql = sql +
    "SELECT " +
    head +
    (if self.cols.length() == 0 { "*" } else { self.cols.join(", ") }) +
    " FROM " +
    source_sql(self.from_, params)
  for j in self.joins {
    sql = sql + " " + j.kind + " " + source_sql(j.src, params)
    if j.using_.length() > 0 {
      sql = sql + " USING (" + j.using_.join(", ") + ")"
    } else if j.on != "" {
      sql = sql + " ON " + j.on
    }
  }
  let where_sql = self.filter.sql(params)
  if where_sql != "" {
    sql = sql + " WHERE " + where_sql
  }
  if self.groups.length() > 0 {
    sql = sql + " GROUP BY " + self.groups.join(", ")
  }
  if self.havings.length() > 0 {
    let hparts : Array[String] = []
    for h in self.havings {
      hparts.push(cond_sql(h, params))
    }
    sql = sql + " HAVING " + hparts.join(" AND ")
  }
  // Set operations chain after this query's core; a trailing ORDER BY / LIMIT then
  // applies to the whole compound (SQL binds them to the last query otherwise).
  // `low` tracks the loosest-binding operator already in the chain: appending a
  // tighter one would silently re-group everything to its left, so that left side
  // becomes a derived table first.
  let mut low = 99
  for so in self.set_ops {
    let (op, other) = so
    let prec = set_prec(op)
    if prec > low {
      sql = derived(sql)
      low = 99
    }
    let (sub_sql, sub_params) = other.build()
    sql = sql +
      " " +
      op +
      " " +
      (if other.is_atom() { sub_sql } else { derived(sub_sql) })
    for p in sub_params {
      params.push(p)
    }
    if prec < low {
      low = prec
    }
  }
  if self.orders.length() > 0 {
    let oparts : Array[String] = []
    for o in self.orders {
      oparts.push(order_term_sql(o))
    }
    sql = sql + " ORDER BY " + oparts.join(", ")
  }
  match self.limit_ {
    Some(n) => sql = sql + " LIMIT " + n.to_string()
    None =>
      // SQLite and MySQL reject a bare OFFSET (the grammar is `LIMIT n [OFFSET m]`),
      // so synthesise an effectively-unbounded LIMIT when only OFFSET is set. i64-max
      // is accepted by SQLite, MySQL, and Postgres alike.
      if self.offset_ is Some(_) {
        sql = sql + " LIMIT 9223372036854775807"
      }
  }
  match self.offset_ {
    Some(n) => sql = sql + " OFFSET " + n.to_string()
    None => ()
  }
  match self.lock_ {
    Some(lock) => sql = sql + " " + lock_sql(lock)
    None => ()
  }
  (sql, params)
}

///|
/// The SQL text of a row-locking clause: `FOR UPDATE`/`FOR SHARE`, an optional `OF a, b`, and a
/// trailing `NOWAIT` or `SKIP LOCKED`.
fn lock_sql(lock : LockClause) -> String {
  let mut s = match lock.mode {
    ForUpdate => "FOR UPDATE"
    ForShare => "FOR SHARE"
  }
  if lock.of.length() > 0 {
    s = s + " OF " + lock.of.join(", ")
  }
  if lock.nowait {
    s = s + " NOWAIT"
  } else if lock.skip_locked {
    s = s + " SKIP LOCKED"
  }
  s
}
