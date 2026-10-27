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
fn order_sql(o : Order) -> String {
  match o {
    Asc => "ASC"
    Desc => "DESC"
  }
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
pub extend Order with Eq::{not_equal, equal}

///|
pub extend Nulls with Eq::{not_equal, equal}
