///|
struct Cond {
  col : String
  op : String
  val : Value
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
      parts.push(ic.col + " " + op + " (" + placeholders.join(", ") + ")")
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
    parts.join(" AND ")
  }
}
