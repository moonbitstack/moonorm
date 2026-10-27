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
        (col + kw + ph.join(", ") + ")", vals)
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
  let body = parts.join(sep)
  (if parts.length() > 1 { "(" + body + ")" } else { body }, params)
}
