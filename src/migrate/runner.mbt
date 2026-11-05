// The revision runner: what Alembic's `upgrade`, `downgrade`, `stamp` and `history`
// commands do. It turns a target into an ordered list of steps — a revision's
// operations rendered for a dialect plus the bookkeeping row that records it — and
// runs each step in its own transaction, so a failure halfway through a history leaves
// the database at a revision boundary rather than inside one.
//
// The plan and the run are separate functions on purpose: `upgrade_sql` returns the
// exact statements `upgrade` executes, which is what an offline run prints and what a
// driver that lives on the other side of an async seam (PostgreSQL) executes.

///|
/// One statement to run, with the values it binds.
pub(all) struct Statement {
  sql : String
  params : Array[@moondb.Value]
}

///|
/// One revision's worth of work: the operations rendered, in order, plus the
/// bookkeeping statement. A runner executes every statement of a step in one
/// transaction.
pub(all) struct Step {
  id : String
  name : String
  statements : Array[Statement]
}

///|
/// Render a step's statements: each operation for `dialect`, then the bookkeeping
/// statement that records the revision.
fn step_of(
  migrator : Migrator,
  revision : Revision,
  ops : Array[Op],
  dialect : @query.Dialect,
  record : Bool,
) -> Step raise @moondb.DbError {
  let statements : Array[Statement] = []
  for op in ops {
    for sql in op.to_sql(dialect) {
      statements.push({ sql, params: [], })
    }
  }
  if record {
    statements.push({
      sql: "INSERT INTO " +
      migrator.revisions_table +
      " (id, name) VALUES (?, ?)",
      params: [@moondb.Text(revision.id), @moondb.Text(revision.name)],
    })
  }
  { id: revision.id, name: revision.name, statements, }
}

///|
/// Create the revisions table if it is absent. Idempotent, like the older
/// `schema_migrations` table, so it is safe to call before every command.
///
/// The width is explicit because MySQL cannot index a bare `TEXT` column and the
/// primary key is what makes a re-applied revision a conflict rather than a duplicate.
pub fn Migrator::ensure_revisions_table(
  self : Migrator,
  sess : @session.Session,
) -> Unit raise @moondb.DbError {
  sess.execute(
    "CREATE TABLE IF NOT EXISTS " +
    self.revisions_table +
    " (id VARCHAR(255) PRIMARY KEY, name TEXT NOT NULL)",
    [],
  )
  |> ignore
}

///|
/// The revisions this database has applied, in the order the graph puts them.
pub fn Migrator::applied_revisions(
  self : Migrator,
  sess : @session.Session,
  revisions : Array[Revision],
) -> Array[String] raise @moondb.DbError {
  self.ensure_revisions_table(sess)
  let rows = sess.query(
    "SELECT id FROM " + self.revisions_table + " ORDER BY id ASC",
    [],
  )
  let recorded : Array[String] = []
  for row in rows {
    recorded.push(row.text(0))
  }
  // Recorded ids are ordered by name, which says nothing about the graph; the
  // topological order is what a caller compares and reports against.
  let order = Revision::order(revisions)
  let out : Array[String] = []
  for id in order {
    if recorded.contains(id) {
      out.push(id)
    }
  }
  out
}

///|
/// The statements of an upgrade from `applied` to `target`, one step per revision, in
/// the order to run them. Nothing touches a database, which is what makes this the
/// offline mode: print the steps and run them elsewhere.
pub fn Migrator::upgrade_sql(
  self : Migrator,
  revisions : Array[Revision],
  applied : Array[String],
  target~ : String = "head",
  dialect~ : @query.Dialect = Sqlite,
) -> Array[Step] raise @moondb.DbError {
  let pending = Revision::pending(revisions, applied, target)
  let out : Array[Step] = []
  for id in pending {
    let revision = Revision::find(revisions, id).unwrap()
    out.push(step_of(self, revision, revision.up, dialect, true))
  }
  out
}

///|
/// The statements of a downgrade from `applied` to `target`, descendants first. Each
/// step runs the revision's `down` operations and then forgets the revision.
pub fn Migrator::downgrade_sql(
  self : Migrator,
  revisions : Array[Revision],
  applied : Array[String],
  target~ : String = "base",
  dialect~ : @query.Dialect = Sqlite,
) -> Array[Step] raise @moondb.DbError {
  let doomed = Revision::doomed(revisions, applied, target)
  let out : Array[Step] = []
  for id in doomed {
    let revision = Revision::find(revisions, id).unwrap()
    let statements : Array[Statement] = []
    for op in revision.down {
      for sql in op.to_sql(dialect) {
        statements.push({ sql, params: [], })
      }
    }
    statements.push({
      sql: "DELETE FROM " + self.revisions_table + " WHERE id = ?",
      params: [@moondb.Text(revision.id)],
    })
    out.push({ id: revision.id, name: revision.name, statements, })
  }
  out
}

///|
/// Run a step's statements in one transaction. A step that fails leaves no trace of
/// itself: the operations and the bookkeeping row that records them commit together
/// or not at all, so the database is always at a revision boundary.
fn run_step(sess : @session.Session, step : Step) -> Unit raise @moondb.DbError {
  sess.transaction(() => {
    for statement in step.statements {
      sess.execute(statement.sql, statement.params) |> ignore
    }
  })
}

///|
/// Apply every pending revision up to `target` and return the ids applied, in order.
/// Each revision and the row recording it run in one transaction, so an interrupted
/// upgrade resumes at the revision it did not finish.
///
/// `target` accepts `"head"` (the single tip), `"heads"` (every tip), `"base"` (do
/// nothing) or a revision id.
pub fn Migrator::upgrade(
  self : Migrator,
  sess : @session.Session,
  revisions : Array[Revision],
  target~ : String = "head",
) -> Array[String] raise @moondb.DbError {
  // The graph and the target are checked before the bookkeeping table is touched, so a
  // typo in a revision id fails without leaving a table behind.
  Revision::order(revisions) |> ignore
  Revision::resolve(revisions, target) |> ignore
  self.ensure_revisions_table(sess)
  let applied = self.applied_revisions(sess, revisions)
  let steps = self.upgrade_sql(
    revisions,
    applied,
    target~,
    dialect=sess.dialect(),
  )
  let done : Array[String] = []
  for step in steps {
    run_step(sess, step)
    done.push(step.id)
  }
  done
}

///|
/// Undo every applied revision above `target`, descendants first, and return the ids
/// undone. `downgrade(target="base")` unwinds the whole history.
pub fn Migrator::downgrade(
  self : Migrator,
  sess : @session.Session,
  revisions : Array[Revision],
  target~ : String = "base",
) -> Array[String] raise @moondb.DbError {
  Revision::order(revisions) |> ignore
  Revision::resolve(revisions, target) |> ignore
  self.ensure_revisions_table(sess)
  let applied = self.applied_revisions(sess, revisions)
  let steps = self.downgrade_sql(
    revisions,
    applied,
    target~,
    dialect=sess.dialect(),
  )
  let undone : Array[String] = []
  for step in steps {
    run_step(sess, step)
    undone.push(step.id)
  }
  undone
}

///|
/// Record the database as being at `target` without running any operation — Alembic's
/// `stamp`, which is how an existing database joins a revision history.
///
/// Revisions the target implies are inserted, ones it does not are removed, and no
/// schema operation runs. All of it is one transaction, so a stamp never half-applies.
pub fn Migrator::stamp(
  self : Migrator,
  sess : @session.Session,
  revisions : Array[Revision],
  target~ : String = "head",
) -> Unit raise @moondb.DbError {
  Revision::order(revisions) |> ignore
  Revision::resolve(revisions, target) |> ignore
  self.ensure_revisions_table(sess)
  let applied = self.applied_revisions(sess, revisions)
  let keep = Revision::resolve(revisions, target)
  sess.transaction(() => {
    for id in applied {
      if !keep.contains(id) {
        sess.execute("DELETE FROM " + self.revisions_table + " WHERE id = ?", [
          @moondb.Text(id),
        ])
        |> ignore
      }
    }
    for id in keep {
      if !applied.contains(id) {
        let revision = Revision::find(revisions, id).unwrap()
        sess.execute(
          "INSERT INTO " + self.revisions_table + " (id, name) VALUES (?, ?)",
          [@moondb.Text(revision.id), @moondb.Text(revision.name)],
        )
        |> ignore
      }
    }
  })
}

///|
/// Where the database is: the applied revisions nothing else applied descends from,
/// in graph order. More than one means the database sits on several branch tips.
pub fn Migrator::heads(
  self : Migrator,
  sess : @session.Session,
  revisions : Array[Revision],
) -> Array[String] raise @moondb.DbError {
  let applied = self.applied_revisions(sess, revisions)
  let out : Array[String] = []
  for id in applied {
    let mut child = false
    for other in applied {
      if other != id {
        let r = Revision::find(revisions, other).unwrap()
        if r.parents.contains(id) {
          child = true
        }
      }
    }
    if !child {
      out.push(id)
    }
  }
  out
}

///|
/// The whole history, newest first, each entry marked with whether this database has
/// it — Alembic's `history` and `current` in one call.
pub fn Migrator::history(
  self : Migrator,
  sess : @session.Session,
  revisions : Array[Revision],
) -> Array[HistoryEntry] raise @moondb.DbError {
  let applied = self.applied_revisions(sess, revisions)
  Revision::history(revisions, applied)
}
