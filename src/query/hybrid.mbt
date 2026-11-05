// Hybrid attributes: one definition read two ways.
//
// A hybrid is a value that exists both as a SQL expression over columns and as a
// computed property of a record. SQLAlchemy gets this from a Python property whose
// getter works on an instance and whose class-level evaluation is rewritten into SQL;
// MoonBit has no property interception, so both halves are written out — but written
// once, in one value, which is what stops the two from drifting.
//
// The SQL half is identifier-level text (`{t}.first_name || ' ' || {t}.last_name`), so
// it carries no bound values and can be spliced into a predicate or an ORDER BY by the
// builder. `{t}` is the table qualifier, substituted by `Hybrid::over`, which is what a
// query over a join needs.

///|
/// A computed attribute with two readings: `expr` is SQL over the model's columns, and
/// `read` computes the same value from a record. `expr` writes `{t}` where the table
/// qualifier belongs, so one definition serves an unqualified single-table query and a
/// qualified one over a join.
pub struct Hybrid[T] {
  name : String
  expr : String
  read : (T) -> Value
}

///|
/// Define a hybrid attribute. `expr` is trusted SQL over column names, like
/// `Select::raw`: it may contain literals and operators, but no bound values — a
/// placeholder there would have no parameter to bind to. `read` must produce the value
/// the expression evaluates to; the pair is what a test comparing both readings
/// checks.
pub fn[T] hybrid(
  name : String,
  expr : String,
  read : (T) -> Value,
) -> Hybrid[T] {
  { name, expr, read, }
}

///|
/// The attribute's name — what its projection is labelled with.
pub fn[T] Hybrid::name(self : Hybrid[T]) -> String {
  self.name
}

///|
/// The expression as written, with `{t}` still in it — for a query with one table and
/// no ambiguity.
pub fn[T] Hybrid::expr(self : Hybrid[T]) -> String {
  self.expr
}

///|
/// The expression with `{t}` replaced by `table`, for a query that joins and has to say
/// which table the columns come from.
pub fn[T] Hybrid::over(self : Hybrid[T], table : String) -> String {
  replace_all(self.expr, "{t}", table)
}

///|
/// The SQL expression to use in this query: `table` when there is one, the expression
/// as written otherwise.
pub fn[T] Hybrid::sql(self : Hybrid[T], table? : String) -> String {
  match table {
    Some(t) => self.over(t)
    None => self.expr
  }
}

///|
/// The attribute's value on one record — the in-memory reading of the same definition.
pub fn[T] Hybrid::value(self : Hybrid[T], record : T) -> Value {
  (self.read)(record)
}

///|
/// Replace every occurrence of `needle` in `text`. Used for the `{t}` table
/// placeholder, so the needle and the expressions it appears in are ASCII.
fn replace_all(text : String, needle : String, replacement : String) -> String {
  if needle == "" {
    return text
  }
  let width = needle.length()
  let sb = StringBuilder()
  let mut at = 0
  while at < text.length() {
    let mut hit = at + width <= text.length()
    if hit {
      let mut k = 0
      while k < width {
        if text[at + k] != needle[k] {
          hit = false
        }
        k = k + 1
      }
    }
    if hit {
      sb.write_string(replacement)
      at = at + width
    } else {
      sb.write_char(text[at].unsafe_to_char())
      at = at + 1
    }
  }
  sb.to_string()
}

///|
/// The table a query reads from, when it is one named table — what a hybrid's `{t}`
/// placeholder is filled with. A derived table or a LATERAL has no name to qualify
/// with, so those return `None` and the caller has to name one.
fn Select::qualifier(self : Select) -> String? {
  match self.from_ {
    Tbl(name) => Some(name)
    Alias(_, name) => Some(name)
    _ => None
  }
}

///|
/// The hybrid's expression, qualified for this query: `table` when the caller names one,
/// the query's own table when its `FROM` is a named table, and the expression as written
/// when it has no `{t}` to fill.
///
/// Raises when the expression needs a qualifier and the query has none to offer, rather
/// than splicing a `{t}` into SQL the server would reject.
fn[T] Select::hybrid_sql(
  self : Select,
  h : Hybrid[T],
  table : String?,
) -> String raise @moondb.DbError {
  match table {
    Some(name) => h.over(name)
    None =>
      if !h.expr().contains("{t}") {
        h.expr()
      } else {
        match self.qualifier() {
          Some(name) => h.over(name)
          None =>
            raise @moondb.QueryError(
              "the hybrid " +
              h.name() +
              " uses {t} and this query reads from a derived table: name a table",
            )
        }
      }
  }
}

///|
/// Filter on a hybrid attribute: `expr op ?`. The expression is the hybrid's own, so the
/// predicate means the same thing the in-memory reading computes, and the value binds
/// as a parameter like any other.
pub fn[T] Select::where_hybrid(
  self : Select,
  h : Hybrid[T],
  op : String,
  val : Value,
  table? : String,
) -> Select raise @moondb.DbError {
  self.where_(self.hybrid_sql(h, table), op, val)
}

///|
/// Order by a hybrid attribute — the usual reason to define one, since a computed
/// column is not available to `ORDER BY` under its name.
pub fn[T] Select::order_hybrid(
  self : Select,
  h : Hybrid[T],
  ord : Order,
  table? : String,
) -> Select raise @moondb.DbError {
  self.order_by(self.hybrid_sql(h, table), ord)
}

///|
/// Project a hybrid attribute under its name, so a fetched row carries the computed
/// value the database worked out — `expr AS name`, SQLAlchemy's `hybrid_property` in a
/// `select()`.
pub fn[T] Select::project_hybrid(
  self : Select,
  h : Hybrid[T],
  table? : String,
) -> Select raise @moondb.DbError {
  self.label(self.hybrid_sql(h, table), h.name())
}
