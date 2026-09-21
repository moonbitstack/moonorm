///|
/// The bound-value type is moondb's dialect-neutral [`@moondb.Value`], re-exported
/// here so the builder's public surface reads as `Value` (and its constructors —
/// `Int`, `Text`, `Null`, …) stay unqualified) while the actual type is the one every
/// moondb driver speaks. Values are always carried out-of-band as parameters, never
/// interpolated into the SQL string — that is what makes the builder injection-safe.
pub using @moondb {type Value}

///|
/// Sort direction for an ORDER BY term.
pub(all) enum Order {
  Asc
  Desc
} derive(Eq)

///|
/// Where NULLs sort in an ORDER BY term (SQLAlchemy's `nulls_first()` /
/// `nulls_last()`). `Auto` emits nothing and leaves the placement to the server,
/// which differs: PostgreSQL sorts NULLs last ascending, SQLite first. `First` /
/// `Last` say it explicitly; MySQL has no such syntax and rejects it.
pub(all) enum Nulls {
  Auto
  First
  Last
} derive(Eq)

///|
/// The SQL dialect a statement renders for. Most of the builder is dialect-neutral
/// — it emits `?` placeholders and standard clauses that every backend accepts —
/// but a few constructs genuinely differ: upsert is `ON CONFLICT ... DO UPDATE` on
/// SQLite and PostgreSQL versus `ON DUPLICATE KEY UPDATE` on MySQL, and `RETURNING`
/// exists on SQLite and PostgreSQL but not MySQL. `build_for` takes a `Dialect` so
/// those render correctly; the no-argument `build` renders the SQLite/PostgreSQL
/// form, which is also what the `?`-placeholder default targets.
pub(all) enum Dialect {
  Sqlite
  Postgres
  Mysql
} derive(Eq)

///|
fn order_sql(o : Order) -> String {
  match o {
    Asc => "ASC"
    Desc => "DESC"
  }
}

///|
struct Cond {
  col : String
  op : String
  val : Value
}

///|
/// One ORDER BY term: the column, its direction, and where NULLs go.
struct OrderTerm {
  col : String
  ord : Order
  nulls : Nulls
}

///|
fn order_term_sql(t : OrderTerm) -> String {
  let base = t.col + " " + order_sql(t.ord)
  match t.nulls {
    Auto => base
    First => base + " NULLS FIRST"
    Last => base + " NULLS LAST"
  }
}

///|
/// Render one scalar comparison, pushing its bound value onto `params`. `= NULL` and
/// `!= NULL` never match under three-valued logic, so a NULL equality folds to
/// `IS NULL` / `IS NOT NULL` — SQLAlchemy's `== None` fold — and binds nothing.
fn cond_sql(c : Cond, params : Array[Value]) -> String {
  if c.val is Null && (c.op == "=" || c.op == "!=" || c.op == "<>") {
    return c.col + (if c.op == "=" { " IS NULL" } else { " IS NOT NULL" })
  }
  params.push(c.val)
  c.col + " " + c.op + " ?"
}

// ---- FROM sources ----

///|
/// What a `FROM` or a `JOIN` names. A bare table is `Tbl`; `Sub` is a derived table
/// (a whole `Select`, whose bound values thread into the enclosing statement's
/// params at the position the subquery renders); `Alias` names either of those, which
/// PostgreSQL and MySQL require of a derived table; `Lateral` lets a derived table
/// reference the columns of the sources to its left (PostgreSQL and MySQL 8.0.14+;
/// SQLite has no LATERAL).
pub(all) enum Source {
  Tbl(String)
  Sub(Select)
  Alias(Source, String)
  Lateral(Source)
}

///|
/// What can stand where a table is expected. A `String` is the table name — so
/// `select("users")` and `join("teams", …)` keep reading as they always did — and a
/// `Source` is anything richer (a derived table, an alias, a LATERAL).
pub(open) trait AsSource {
  fn to_source(Self) -> Source
}

///|
pub impl AsSource for String with fn to_source(self) {
  Tbl(self)
}

///|
pub impl AsSource for Source with fn to_source(self) {
  self
}

///|
/// Render a source, appending any bound values a derived table carries to `params`
/// so they stay in the SQL text's left-to-right order.
fn source_sql(src : Source, params : Array[Value]) -> String {
  match src {
    Tbl(name) => name
    Sub(q) => {
      let (sub_sql, sub_params) = q.build()
      for p in sub_params {
        params.push(p)
      }
      "(" + sub_sql + ")"
    }
    Alias(inner, name) => source_sql(inner, params) + " AS " + name
    Lateral(inner) => "LATERAL " + source_sql(inner, params)
  }
}

///|
/// A single JOIN clause: its keyword (`JOIN` / `LEFT JOIN` / …), the joined source,
/// and either a raw `ON` predicate (an identifier-level expression, never a bound
/// value) or a `USING` column list. A `CROSS JOIN` carries neither.
struct JoinClause {
  kind : String
  src : Source
  on : String
  using_ : Array[String]
}

///|
fn join(parts : Array[String], sep : String) -> String {
  let mut out = ""
  for i = 0; i < parts.length(); i = i + 1 {
    if i > 0 {
      out = out + sep
    }
    out = out + parts[i]
  }
  out
}

// ---- expressions ----

///|
/// A function call as a column expression: `func("coalesce", ["a", "b"])` renders
/// `coalesce(a, b)`. This is SQLAlchemy's `func.*` without the attribute magic — the
/// arguments are identifier-level SQL, rendered verbatim like `Select::raw`, so bind
/// a value by placing a `?` and passing it through the surrounding clause.
pub fn func(name : String, args : Array[String]) -> String {
  name + "(" + join(args, ", ") + ")"
}

///|
/// A type conversion: `cast("price", "NUMERIC(10,2)")` renders
/// `CAST(price AS NUMERIC(10,2))`. Identifier-level like `func`.
pub fn cast(expr : String, ty : String) -> String {
  "CAST(" + expr + " AS " + ty + ")"
}

///|
/// A searched `CASE` expression: each `(condition, result)` pair becomes one
/// `WHEN … THEN …`, and a non-empty `else_` the trailing `ELSE`. Identifier-level
/// like `func`. With no branches there is nothing to test, so it folds to `else_`
/// (or `NULL`), which is what an all-branchless `CASE` would evaluate to anyway.
pub fn case_(whens : Array[(String, String)], else_? : String = "") -> String {
  if whens.length() == 0 {
    return if else_ == "" { "NULL" } else { else_ }
  }
  let parts : Array[String] = []
  for w in whens {
    parts.push("WHEN " + w.0 + " THEN " + w.1)
  }
  let tail = if else_ == "" { "" } else { " ELSE " + else_ }
  "CASE " + join(parts, " ") + tail + " END"
}

// ---- predicates ----

///|
/// A boolean predicate tree — the parameter-safe way to express arbitrary
/// `AND`/`OR`/`NOT` groupings (SQLAlchemy's `and_()` / `or_()` / `not_()`), which the
/// flat `where_`/`eq` API (always joined by `AND`) cannot. Every comparison binds its
/// value as a placeholder, so a `(a = ? OR b = ?)` filter stays fully parameterised.
/// Attach one to a query with `Select::where_pred`.
pub(all) enum Predicate {
  Cmp(col~ : String, op~ : String, val~ : Value)
  InList(col~ : String, vals~ : Array[Value], negated~ : Bool)
  Exists(sub~ : Select, negated~ : Bool)
  And(Array[Predicate])
  Or(Array[Predicate])
  Not(Predicate)
}

///|
/// Render a predicate to its SQL fragment and the values it binds, in text order. A
/// multi-child `And`/`Or` is wrapped in parentheses so nesting composes correctly.
pub fn Predicate::build(self : Predicate) -> (String, Array[Value]) {
  match self {
    Cmp(col~, op~, val~) => {
      let params : Array[Value] = []
      let sql = cond_sql({ col, op, val, }, params)
      (sql, params)
    }
    InList(col~, vals~, negated~) =>
      // Empty `IN` matches nothing, empty `NOT IN` matches everything (SQLAlchemy's
      // constant fold). `IN/NOT IN (NULL)` would get both wrong via three-valued
      // NULL logic (`NOT IN (NULL)` is never true).
      if vals.length() == 0 {
        (if negated { "1 = 1" } else { "1 = 0" }, [])
      } else {
        let ph : Array[String] = []
        for _v in vals {
          ph.push("?")
        }
        let kw = if negated { " NOT IN (" } else { " IN (" }
        (col + kw + join(ph, ", ") + ")", vals)
      }
    Exists(sub~, negated~) => {
      let (s, p) = sub.build()
      ((if negated { "NOT EXISTS (" } else { "EXISTS (" }) + s + ")", p)
    }
    And(ps) =>
      if ps.length() == 0 {
        ("1 = 1", [])
      } else {
        predicate_combine(ps, " AND ")
      }
    Or(ps) =>
      if ps.length() == 0 {
        ("1 = 0", [])
      } else {
        predicate_combine(ps, " OR ")
      }
    Not(p) => {
      let (s, pa) = p.build()
      ("NOT (" + s + ")", pa)
    }
  }
}

///|
/// Join child predicates with `sep`, wrapping the group in parentheses when it has
/// more than one child, and concatenating their bound values in text order.
fn predicate_combine(
  ps : Array[Predicate],
  sep : String,
) -> (String, Array[Value]) {
  let parts : Array[String] = []
  let params : Array[Value] = []
  for p in ps {
    let (s, pa) = p.build()
    parts.push(s)
    for v in pa {
      params.push(v)
    }
  }
  let body = join(parts, sep)
  (if parts.length() > 1 { "(" + body + ")" } else { body }, params)
}

// ---- WHERE ----

///|
/// A `col IN (subquery)` / `col NOT IN (subquery)` predicate: the subquery is a
/// full `Select`, whose bound parameters splice in at the point the predicate is
/// rendered. Keeping subquery predicates separate from the scalar `conds` lets the
/// builder concatenate the two params streams in the exact order the SQL text emits
/// them (scalar predicates first, then subqueries), so binding stays index-aligned.
priv struct SubCond {
  col : String
  op : String
  sub : Select
}

///|
/// A `col IN (?, ?, …)` / `col NOT IN (?, …)` predicate over an explicit value list
/// (as opposed to `SubCond`, whose right-hand side is a subquery). Each value binds
/// as its own placeholder, so a set-membership filter — the workhorse of an
/// N+1-avoiding batch load, `WHERE fk IN (all the parent keys)` — stays fully
/// parameterised.
priv struct InCond {
  col : String
  negated : Bool
  vals : Array[Value]
}

///|
/// The WHERE clause of any statement — SELECT, UPDATE and DELETE share it, so the
/// three render identical SQL and bind their values in one order rather than three.
struct Where {
  conds : Array[Cond]
  in_conds : Array[InCond]
  sub_conds : Array[SubCond]
  preds : Array[Predicate]
}

///|
fn Where::new() -> Where {
  { conds: [], in_conds: [], sub_conds: [], preds: [], }
}

///|
fn Where::dup(self : Where) -> Where {
  {
    conds: self.conds.copy(),
    in_conds: self.in_conds.copy(),
    sub_conds: self.sub_conds.copy(),
    preds: self.preds.copy(),
  }
}

///|
/// The conjunction of every attached predicate, or `""` when there is none, pushing
/// bound values onto `params` in text order: scalar comparisons, then `IN (values)`,
/// then subqueries, then predicate trees.
fn Where::sql(self : Where, params : Array[Value]) -> String {
  let parts : Array[String] = []
  for c in self.conds {
    parts.push(cond_sql(c, params))
  }
  for ic in self.in_conds {
    // Empty `IN` matches nothing, empty `NOT IN` matches everything — a constant
    // predicate, not `IN (NULL)` (which is never true under NULL logic).
    if ic.vals.length() == 0 {
      parts.push(if ic.negated { "1 = 1" } else { "1 = 0" })
    } else {
      let placeholders : Array[String] = []
      for v in ic.vals {
        placeholders.push("?")
        params.push(v)
      }
      let op = if ic.negated { "NOT IN" } else { "IN" }
      parts.push(ic.col + " " + op + " (" + join(placeholders, ", ") + ")")
    }
  }
  for sc in self.sub_conds {
    let (sub_sql, sub_params) = sc.sub.build()
    parts.push(sc.col + " " + sc.op + " (" + sub_sql + ")")
    for p in sub_params {
      params.push(p)
    }
  }
  for pred in self.preds {
    let (ps, pp) = pred.build()
    parts.push(ps)
    for p in pp {
      params.push(p)
    }
  }
  if parts.length() == 0 {
    ""
  } else {
    join(parts, " AND ")
  }
}

// ---- SELECT ----

///|
/// A common table expression: `name AS (subquery)`. CTEs render in a single leading
/// `WITH` clause and their bound parameters come first in the final params list,
/// matching their leading position in the SQL text. When `recursive`, the whole
/// clause is a `WITH RECURSIVE` (the keyword modifies the clause, not the entry, so
/// one recursive CTE turns the leading `WITH` recursive for all of them).
struct Cte {
  name : String
  sub : Select
  recursive : Bool
}

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
  mut limit_ : Int?
  mut offset_ : Int?
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
  read? : Bool = false,
  of? : Array[String] = [],
  nowait? : Bool = false,
  skip_locked? : Bool = false,
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
  partition_by? : Array[String] = [],
  order_by? : Array[(String, Order)] = [],
  as_? : String = "",
) -> Select {
  let inner : Array[String] = []
  if partition_by.length() > 0 {
    inner.push("PARTITION BY " + join(partition_by, ", "))
  }
  if order_by.length() > 0 {
    let oparts : Array[String] = []
    for o in order_by {
      oparts.push(o.0 + " " + order_sql(o.1))
    }
    inner.push("ORDER BY " + join(oparts, ", "))
  }
  let over = expr + " OVER (" + join(inner, " ") + ")"
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
  all? : Bool = false,
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
  nulls? : Nulls = Auto,
) -> Select {
  let s = self.dup()
  s.orders.push({ col, ord, nulls, })
  s
}

///|
/// Cap how many rows come back.
pub fn Select::limit(self : Select, n : Int) -> Select {
  let s = self.dup()
  s.limit_ = Some(n)
  s
}

///|
/// Skip the first `n` rows. Paired with `limit` this is a page.
pub fn Select::offset(self : Select, n : Int) -> Select {
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
fn set_prec(op : String) -> Int {
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
      join(cte_parts, ", ") +
      " "
  }
  let head = if self.distinct_on_.length() > 0 {
    "DISTINCT ON (" + join(self.distinct_on_, ", ") + ") "
  } else if self.distinct_ {
    "DISTINCT "
  } else {
    ""
  }
  sql = sql +
    "SELECT " +
    head +
    (if self.cols.length() == 0 { "*" } else { join(self.cols, ", ") }) +
    " FROM " +
    source_sql(self.from_, params)
  for j in self.joins {
    sql = sql + " " + j.kind + " " + source_sql(j.src, params)
    if j.using_.length() > 0 {
      sql = sql + " USING (" + join(j.using_, ", ") + ")"
    } else if j.on != "" {
      sql = sql + " ON " + j.on
    }
  }
  let where_sql = self.filter.sql(params)
  if where_sql != "" {
    sql = sql + " WHERE " + where_sql
  }
  if self.groups.length() > 0 {
    sql = sql + " GROUP BY " + join(self.groups, ", ")
  }
  if self.havings.length() > 0 {
    let hparts : Array[String] = []
    for h in self.havings {
      hparts.push(cond_sql(h, params))
    }
    sql = sql + " HAVING " + join(hparts, " AND ")
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
    sql = sql + " ORDER BY " + join(oparts, ", ")
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
    s = s + " OF " + join(lock.of, ", ")
  }
  if lock.nowait {
    s = s + " NOWAIT"
  } else if lock.skip_locked {
    s = s + " SKIP LOCKED"
  }
  s
}

///|
/// A lightweight table descriptor: a table `name` plus its known `columns`. It is
/// the hand-written stand-in for SQLAlchemy's `Table(...)` metadata object —
/// MoonBit has no reflection, so the schema is declared explicitly rather than
/// introspected. `select()` turns it into a `Select` with every column projected.
pub(all) struct Table {
  name : String
  columns : Array[String]
}

///|
/// Start a SELECT over this table with all of its declared `columns` projected
/// (an empty `columns` yields `SELECT *`, matching `select(name)`).
pub fn Table::select(self : Table) -> Select {
  let s = select(self.name)
  for c in self.columns {
    s.cols.push(c)
  }
  s
}

// ---- INSERT ----

///|
/// The right-hand side of one `DO UPDATE` assignment in an upsert. `Bound` sets the
/// column to a bound value (`col = ?`), just like a normal update. `Excluded` sets
/// it to the value the conflicting `INSERT` tried to write — `excluded.col` on
/// SQLite/PostgreSQL, `VALUES(col)` on MySQL — which is how "insert or overwrite
/// with the new row" is spelled.
priv enum ConflictValue {
  Bound(Value)
  Excluded
}

///|
priv struct ConflictAssign {
  col : String
  value : ConflictValue
}

///|
/// The `ON CONFLICT` / `ON DUPLICATE KEY` clause of an upsert: the conflict-target
/// columns (the unique key that may collide — used by SQLite/PostgreSQL, implicit on
/// MySQL), the `DO UPDATE` assignments, and whether the intent is `DO NOTHING`.
struct Conflict {
  targets : Array[String]
  assigns : Array[ConflictAssign]
  mut do_nothing : Bool
}

///|
fn Conflict::dup(self : Conflict) -> Conflict {
  {
    targets: self.targets.copy(),
    assigns: self.assigns.copy(),
    do_nothing: self.do_nothing,
  }
}

///|
/// An INSERT statement builder, with optional upsert (`ON CONFLICT`) and
/// `RETURNING` support. Generative like `Select`.
pub struct Insert {
  table : String
  cols : Array[String]
  vals : Array[Value]
  // Additional value tuples for a multi-row INSERT, each in `cols` order.
  extra_rows : Array[Array[Value]]
  mut conflict : Conflict?
  returning : Array[String]
}

///|
/// Start an INSERT into `table`. Values are bound, never spliced, so a column
/// holding a quote or a semicolon is a value and not syntax.
pub fn insert(table : String) -> Insert {
  { table, cols: [], vals: [], extra_rows: [], conflict: None, returning: [], }
}

///|
fn Insert::dup(self : Insert) -> Insert {
  {
    table: self.table,
    cols: self.cols.copy(),
    vals: self.vals.copy(),
    extra_rows: self.extra_rows.copy(),
    conflict: match self.conflict {
      Some(c) => Some(c.dup())
      None => None
    },
    returning: self.returning.copy(),
  }
}

///|
/// Set a column to a value.
pub fn Insert::set(self : Insert, col : String, val : Value) -> Insert {
  let ins = self.dup()
  ins.cols.push(col)
  ins.vals.push(val)
  ins
}

///|
/// Append another row to a multi-row INSERT, in the same column order the first row
/// established via `set` (SQLAlchemy's multi-values / `executemany`). Every value
/// binds as its own placeholder, so a bulk insert stays injection-safe; each `row`
/// must supply one value per column.
pub fn Insert::values(self : Insert, row : Array[Value]) -> Insert {
  let ins = self.dup()
  ins.extra_rows.push(row)
  ins
}

///|
/// Ensure a `Conflict` exists, creating an empty one (no targets, no assigns) if
/// this is the first upsert call.
fn Insert::ensure_conflict(self : Insert) -> Conflict {
  match self.conflict {
    Some(c) => c
    None => {
      let c = { targets: [], assigns: [], do_nothing: false, }
      self.conflict = Some(c)
      c
    }
  }
}

///|
/// Turn this INSERT into an upsert keyed on `targets` — the columns of the unique
/// index that may collide (SQLAlchemy's `index_elements`). Chain `do_update` /
/// `do_update_excluded` to say what to change on a collision, or leave it and call
/// `do_nothing`. SQLite and PostgreSQL name the conflict target explicitly;
/// `build_for(Mysql)` ignores it (MySQL infers the key), so pass it regardless and
/// the right dialect uses it.
pub fn Insert::on_conflict(self : Insert, targets : Array[String]) -> Insert {
  let ins = self.dup()
  let c = ins.ensure_conflict()
  for t in targets {
    c.targets.push(t)
  }
  ins
}

///|
/// On a conflict, set `col` to a bound value (`col = ?`). The value binds as a
/// parameter after the inserted values, so an upsert stays injection-safe.
pub fn Insert::do_update(self : Insert, col : String, val : Value) -> Insert {
  let ins = self.dup()
  ins.ensure_conflict().assigns.push({ col, value: Bound(val), })
  ins
}

///|
/// On a conflict, set `col` to the value the failed insert tried to write
/// (`excluded.col` on SQLite/PostgreSQL, `VALUES(col)` on MySQL). This is the
/// "overwrite with the incoming row" upsert.
pub fn Insert::do_update_excluded(self : Insert, col : String) -> Insert {
  let ins = self.dup()
  ins.ensure_conflict().assigns.push({ col, value: Excluded, })
  ins
}

///|
/// On a conflict, keep the existing row and change nothing (`ON CONFLICT DO
/// NOTHING`). MySQL has no such form, so `build_for(Mysql)` renders a no-op
/// self-assignment instead.
pub fn Insert::do_nothing(self : Insert) -> Insert {
  let ins = self.dup()
  ins.ensure_conflict().do_nothing = true
  ins
}

///|
/// Return `col` from each inserted (or upserted) row. On SQLite and PostgreSQL this
/// appends `RETURNING`, so a caller reads the server-assigned id or a
/// default/trigger-computed value back in the same round trip instead of a second
/// SELECT. Repeatable. `build_for(Mysql)` drops it — MySQL has no `RETURNING`.
pub fn Insert::returning(self : Insert, col : String) -> Insert {
  let ins = self.dup()
  ins.returning.push(col)
  ins
}

///|
/// Return every column of each inserted row (`RETURNING *`). See `returning`.
pub fn Insert::returning_all(self : Insert) -> Insert {
  self.returning("*")
}

///|
/// Render to `(sql, params)` for the SQLite/PostgreSQL dialect. Equivalent to
/// `build_for(Sqlite)`; kept as the no-argument default because plain inserts and
/// the `?`-placeholder convention target this form.
pub fn Insert::build(self : Insert) -> (String, Array[Value]) {
  self.build_for(Sqlite)
}

///|
/// Render to `(sql, params)` for `dialect`, with `?` placeholders for every bound
/// value. Bound values appear in params in SQL-text order: the inserted `VALUES`
/// first, then any `DO UPDATE SET col = ?` values. Upsert renders as `ON CONFLICT`
/// on SQLite/PostgreSQL and `ON DUPLICATE KEY UPDATE` on MySQL; `RETURNING` is
/// emitted on SQLite/PostgreSQL and omitted on MySQL.
pub fn Insert::build_for(
  self : Insert,
  dialect : Dialect,
) -> (String, Array[Value]) {
  let params : Array[Value] = []
  // One `(?, ?, …)` tuple per row — the first from `set`, then any bulk `values`.
  let tuples : Array[String] = []
  let emit_tuple = fn(row : Array[Value]) {
    let ph : Array[String] = []
    for v in row {
      ph.push("?")
      params.push(v)
    }
    tuples.push("(" + join(ph, ", ") + ")")
  }
  // Without a `set` there is no first row; emitting one anyway would put an empty
  // `()` tuple in front of the bulk rows.
  if self.vals.length() > 0 {
    emit_tuple(self.vals)
  }
  for row in self.extra_rows {
    emit_tuple(row)
  }
  let mut sql = "INSERT INTO " + self.table
  if self.cols.length() > 0 {
    sql = sql + " (" + join(self.cols, ", ") + ")"
  }
  if tuples.length() == 0 {
    // Nothing to insert but the row itself: the column list is empty too, and an
    // empty `() VALUES ()` is MySQL's spelling where the others say DEFAULT VALUES.
    sql = sql +
      (if dialect == Mysql { " () VALUES ()" } else { " DEFAULT VALUES" })
  } else {
    sql = sql + " VALUES " + join(tuples, ", ")
  }
  match self.conflict {
    Some(c) => sql = sql + render_conflict(c, dialect, self.cols, params)
    None => ()
  }
  if self.returning.length() > 0 && dialect != Mysql {
    sql = sql + " RETURNING " + join(self.returning, ", ")
  }
  (sql, params)
}

///|
/// Render an upsert clause for `dialect`, pushing any bound update values onto
/// `params` (they follow the inserted values in SQL-text order). `insert_cols` is
/// the inserted column list, used only to pick a valid no-op assignment for MySQL's
/// `DO NOTHING`, which has no native spelling.
fn render_conflict(
  c : Conflict,
  dialect : Dialect,
  insert_cols : Array[String],
  params : Array[Value],
) -> String {
  match dialect {
    Mysql => {
      let sets : Array[String] = []
      if c.do_nothing && c.assigns.length() == 0 {
        // MySQL cannot skip the update list; assign a key column to itself.
        let key = if c.targets.length() > 0 {
          c.targets[0]
        } else if insert_cols.length() > 0 {
          insert_cols[0]
        } else {
          "1"
        }
        sets.push(key + " = " + key)
      } else {
        for a in c.assigns {
          match a.value {
            Bound(v) => {
              sets.push(a.col + " = ?")
              params.push(v)
            }
            Excluded => sets.push(a.col + " = VALUES(" + a.col + ")")
          }
        }
      }
      " ON DUPLICATE KEY UPDATE " + join(sets, ", ")
    }
    _ => {
      let target = if c.targets.length() > 0 {
        " (" + join(c.targets, ", ") + ")"
      } else {
        ""
      }
      if c.do_nothing && c.assigns.length() == 0 {
        " ON CONFLICT" + target + " DO NOTHING"
      } else {
        let sets : Array[String] = []
        for a in c.assigns {
          match a.value {
            Bound(v) => {
              sets.push(a.col + " = ?")
              params.push(v)
            }
            Excluded => sets.push(a.col + " = excluded." + a.col)
          }
        }
        " ON CONFLICT" + target + " DO UPDATE SET " + join(sets, ", ")
      }
    }
  }
}

// ---- UPDATE ----

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
  vals? : Array[Value] = [],
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
  let mut sql = "UPDATE " + self.table + " SET " + join(setparts, ", ")
  let where_sql = self.filter.sql(params)
  if where_sql != "" {
    sql = sql + " WHERE " + where_sql
  }
  if self.returning.length() > 0 && dialect != Mysql {
    sql = sql + " RETURNING " + join(self.returning, ", ")
  }
  (sql, params)
}

// ---- DELETE ----

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
    sql = sql + " RETURNING " + join(self.returning, ", ")
  }
  (sql, params)
}

///|
pub extend Order with Eq::{not_equal, equal}

///|
pub extend Nulls with Eq::{not_equal, equal}

///|
pub extend Dialect with Eq::{not_equal, equal}

///|
pub extend Source with AsSource::{to_source}

///|
pub extend LockMode with Debug::{to_repr}

///|
pub extend LockMode with Eq::{not_equal, equal}

///|
pub extend LockClause with Debug::{to_repr}

///|
pub extend LockClause with Eq::{not_equal, equal}
