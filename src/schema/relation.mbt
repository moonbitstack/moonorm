///|
/// A foreign-key relationship from a source record `S` to a `target` model `T`,
/// resolved by matching `target.key_column` against a `Value` extracted from the
/// source. `to_many` records the cardinality (a 1:N parent->children link versus a
/// N:1 child->parent link) so callers know whether to expect many rows or one.
///
/// Because MoonBit has no attribute interception, touching `hero.team` cannot
/// silently emit a SELECT the way SQLAlchemy's lazy load does. The relationship is
/// therefore a first-class value and the load is explicit — `Session::load` /
/// `Session::load_one` — exactly the eager, explicit shape Diesel's `belonging_to`
/// / preload and GORM's `Preload` take.
pub struct Relation[S, T] {
  target : Model[T]
  key_column : String
  source_key : (S) -> @moondb.Value
  to_many : Bool
}

///|
/// A 1:N relationship: `parent` -> its children in `target`, matched by the child's
/// `foreign_key` column equalling the parent key extracted by `parent_key`, any
/// value a column takes. Load it with `Session::load`, which returns every
/// matching child record.
pub fn[S, T, V : @moondb.ToValue] has_many(
  target : Model[T],
  foreign_key : String,
  parent_key : (S) -> V,
) -> Relation[S, T] {
  {
    target,
    key_column: foreign_key,
    source_key: s => parent_key(s).to_value(),
    to_many: true,
  }
}

///|
/// A N:1 relationship: `child` -> its single parent in `target`, matched by the
/// parent's `target_key` column (usually its primary key) equalling the foreign
/// key extracted from the child by `child_key`. Load it with `Session::load_one`.
pub fn[S, T, V : @moondb.ToValue] belongs_to(
  target : Model[T],
  target_key : String,
  child_key : (S) -> V,
) -> Relation[S, T] {
  {
    target,
    key_column: target_key,
    source_key: s => child_key(s).to_value(),
    to_many: false,
  }
}

///|
/// The `Select` that resolves this relationship for a given `source` record: the
/// target model's projection filtered to `key_column = ?`, with the source-derived
/// value bound (never spliced), so eager loading is injection-safe like every other
/// query. `Session::load` runs this and maps the rows.
pub fn[S, T] Relation::query(
  self : Relation[S, T],
  source : S,
) -> @query.Select {
  self.target.select().where_(self.key_column, "=", (self.source_key)(source))
}

///|
/// The single `Select` that resolves this relationship for *many* sources at once:
/// the target model's projection filtered to `key_column IN (k1, k2, …)`, where the
/// keys are the distinct values extracted from `sources`. This is the query behind
/// an N+1-avoiding batch load — one round trip fetches the related rows of every
/// source, instead of one `query(source)` per source. Every key binds as its own
/// placeholder. With no sources the result filters on the empty set (`IN (NULL)`),
/// matching nothing; `Session::load_batch` short-circuits that case without a query.
/// The source-side key this relationship extracts from a `source` record — the
/// value the target's `key_column` is matched against. Exposed so a batch load can
/// bucket fetched rows back to their sources.
pub fn[S, T] Relation::source_value(
  self : Relation[S, T],
  source : S,
) -> @moondb.Value {
  (self.source_key)(source)
}

///|
/// One SELECT covering every source's related rows — `key_column IN (…)` over the
/// sources' keys — so loading a relation for a list costs one query instead of one
/// per row. `source_value` is what buckets the results back.
pub fn[S, T] Relation::batch_query(
  self : Relation[S, T],
  sources : Array[S],
) -> @query.Select {
  let keys : Array[@moondb.Value] = []
  for s in sources {
    let k = (self.source_key)(s)
    // Distinct keys only: several sources may share one foreign key, and the IN
    // list needs each key once.
    let mut seen = false
    for existing in keys {
      if existing == k {
        seen = true
        break
      }
    }
    if !seen {
      keys.push(k)
    }
  }
  self.target.select().where_in_values(self.key_column, keys)
}

///|
/// A many-to-many relationship from a source `S` to a `target` `T` through a
/// `junction` (association) table — SQLAlchemy's `relationship(secondary=...)`. The
/// junction's `source_fk` column matches a key extracted from the source, and its
/// `target_fk` column matches the target's `target_key`. Resolving the relationship
/// JOINs the target through the junction. Load it with `Session::load_many`; like the
/// 1:N / N:1 relations, MoonBit's lack of attribute interception makes the load an
/// explicit call rather than a lazy attribute access.
pub struct ManyToMany[S, T] {
  target : Model[T]
  junction : String
  source_fk : String
  target_fk : String
  target_key : String
  source_key : (S) -> @moondb.Value
}

///|
/// Define a many-to-many relationship through `junction`. `source_fk` / `target_fk`
/// are the junction columns pointing at the source key and the `target_key`.
pub fn[S, T, V : @moondb.ToValue] many_to_many(
  target : Model[T],
  junction~ : String,
  source_fk~ : String,
  target_fk~ : String,
  target_key~ : String,
  source_key~ : (S) -> V,
) -> ManyToMany[S, T] {
  {
    target,
    junction,
    source_fk,
    target_fk,
    target_key,
    source_key: s => source_key(s).to_value(),
  }
}

///|
/// The `Select` resolving this relationship for a `source`: the target rows joined to
/// the junction on `junction.target_fk = target.target_key`, filtered to
/// `junction.source_fk = ?` with the source key bound (never spliced). The target
/// columns are projected qualified (`target.col`) so a same-named junction column
/// never makes the projection ambiguous. `Session::load_many` runs it and maps.
pub fn[S, T] ManyToMany::query(
  self : ManyToMany[S, T],
  source : S,
) -> @query.Select {
  let s = @query.select(self.target.table)
  for c in self.target.columns {
    s.cols.push(self.target.table + "." + c.name)
  }
  s
  .join(
    self.junction,
    self.junction +
    "." +
    self.target_fk +
    " = " +
    self.target.table +
    "." +
    self.target_key,
  )
  .where_(self.junction + "." + self.source_fk, "=", (self.source_key)(source))
}


///|
/// How a relationship is loaded. `SubqueryLoad` is the default: one `IN` query for a
/// whole list of sources (`selectinload`). `JoinedLoad` fetches through a JOIN against
/// a derived table of the source keys (`joinedload`). `RaiseLoad` refuses, so a caller
/// can assert a relation is not touched here (`raiseload`).
pub(all) enum LoadStrategy {
  SubqueryLoad
  JoinedLoad
  RaiseLoad
}

///|
/// The distinct keys `key` yields from `sources`, in first-seen order.
fn[S] distinct_keys(
  sources : Array[S],
  key : (S) -> @moondb.Value,
) -> Array[@moondb.Value] {
  let keys : Array[@moondb.Value] = []
  for s in sources {
    let k = key(s)
    let mut seen = false
    for existing in keys {
      if existing == k {
        seen = true
        break
      }
    }
    if !seen {
      keys.push(k)
    }
  }
  keys
}

///|
/// The query behind a `JoinedLoad` of a 1:N / N:1 relation: the target rows joined to
/// a derived table of the distinct source keys on `target.key_column =
/// moonorm_src.moonorm_key`. The keys bind as `?`, so the load stays injection-safe.
/// With no sources it matches nothing (`WHERE 1 = 0`) instead of an empty derived
/// table.
pub fn[S, T] Relation::joined_sql(
  self : Relation[S, T],
  sources : Array[S],
) -> (String, Array[@moondb.Value]) {
  let keys = distinct_keys(sources, self.source_key)
  let cols : Array[String] = []
  for c in self.target.columns {
    cols.push(self.target.table + "." + c.name)
  }
  let head = "SELECT " + cols.join(", ") + " FROM " + self.target.table
  if keys.length() == 0 {
    return (head + " WHERE 1 = 0", [])
  }
  let params : Array[@moondb.Value] = []
  let parts : Array[String] = []
  for k in keys {
    parts.push("SELECT ? AS moonorm_key")
    params.push(k)
  }
  let sql = head +
    " JOIN (" +
    parts.join(" UNION ALL ") +
    ") AS moonorm_src ON " +
    self.target.table +
    "." +
    self.key_column +
    " = moonorm_src.moonorm_key"
  (sql, params)
}

///|
/// The junction-side key of a source, so an N:M batch load can bucket every fetched
/// target row back to the source it belongs to.
pub fn[S, T] ManyToMany::source_value(
  self : ManyToMany[S, T],
  source : S,
) -> @moondb.Value {
  (self.source_key)(source)
}

///|
/// The query behind an N:M batch load: target rows joined to the junction, the
/// junction's `source_fk` projected as `moonorm_src` so rows bucket back, filtered to
/// `junction.source_fk IN (…)` with every key bound. Empty sources match nothing.
pub fn[S, T] ManyToMany::batch_sql(
  self : ManyToMany[S, T],
  sources : Array[S],
) -> (String, Array[@moondb.Value]) {
  let keys = distinct_keys(sources, self.source_key)
  let cols : Array[String] = []
  for c in self.target.columns {
    cols.push(self.target.table + "." + c.name)
  }
  cols.push(self.junction + "." + self.source_fk + " AS moonorm_src")
  let head = "SELECT " +
    cols.join(", ") +
    " FROM " +
    self.target.table +
    " JOIN " +
    self.junction +
    " ON " +
    self.junction +
    "." +
    self.target_fk +
    " = " +
    self.target.table +
    "." +
    self.target_key
  let params : Array[@moondb.Value] = []
  let marks : Array[String] = []
  for k in keys {
    marks.push("?")
    params.push(k)
  }
  let where_clause = if marks.length() == 0 {
    " WHERE 1 = 0"
  } else {
    " WHERE " +
    self.junction +
    "." +
    self.source_fk +
    " IN (" +
    marks.join(", ") +
    ")"
  }
  (head + where_clause, params)
}

///|
/// The query behind a `JoinedLoad` of an N:M relation: target rows joined to the
/// junction and to a derived table of the source keys, the junction's `source_fk`
/// projected as `moonorm_src`, joined on `junction.source_fk = moonorm_keys.moonorm_key`.
pub fn[S, T] ManyToMany::joined_sql(
  self : ManyToMany[S, T],
  sources : Array[S],
) -> (String, Array[@moondb.Value]) {
  let keys = distinct_keys(sources, self.source_key)
  let cols : Array[String] = []
  for c in self.target.columns {
    cols.push(self.target.table + "." + c.name)
  }
  cols.push(self.junction + "." + self.source_fk + " AS moonorm_src")
  let head = "SELECT " +
    cols.join(", ") +
    " FROM " +
    self.target.table +
    " JOIN " +
    self.junction +
    " ON " +
    self.junction +
    "." +
    self.target_fk +
    " = " +
    self.target.table +
    "." +
    self.target_key
  if keys.length() == 0 {
    return (head + " WHERE 1 = 0", [])
  }
  let params : Array[@moondb.Value] = []
  let parts : Array[String] = []
  for k in keys {
    parts.push("SELECT ? AS moonorm_key")
    params.push(k)
  }
  let sql = head +
    " JOIN (" +
    parts.join(" UNION ALL ") +
    ") AS moonorm_keys ON " +
    self.junction +
    "." +
    self.source_fk +
    " = moonorm_keys.moonorm_key"
  (sql, params)
}
