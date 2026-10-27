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
    tuples.push("(" + ph.join(", ") + ")")
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
    sql = sql + " (" + self.cols.join(", ") + ")"
  }
  if tuples.length() == 0 {
    // Nothing to insert but the row itself: the column list is empty too, and an
    // empty `() VALUES ()` is MySQL's spelling where the others say DEFAULT VALUES.
    sql = sql +
      (if dialect == Mysql { " () VALUES ()" } else { " DEFAULT VALUES" })
  } else {
    sql = sql + " VALUES " + tuples.join(", ")
  }
  match self.conflict {
    Some(c) => sql = sql + render_conflict(c, dialect, self.cols, params)
    None => ()
  }
  if self.returning.length() > 0 && dialect != Mysql {
    sql = sql + " RETURNING " + self.returning.join(", ")
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
      " ON DUPLICATE KEY UPDATE " + sets.join(", ")
    }
    _ => {
      let target = if c.targets.length() > 0 {
        " (" + c.targets.join(", ") + ")"
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
        " ON CONFLICT" + target + " DO UPDATE SET " + sets.join(", ")
      }
    }
  }
}
