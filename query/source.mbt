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
/// `select("users")` and `"teams".join(…)` keep reading as they always did — and a
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
pub extend Source with AsSource::{to_source}
