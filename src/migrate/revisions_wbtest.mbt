///|
/// A driver that models only the revisions bookkeeping table, and records every
/// statement together with the transaction it ran in — enough to assert both what a
/// run emitted and that each step was bracketed by its own transaction.
struct RevisionDriver {
  mut ids : Array[String]
  log : Array[(String, Int32)]
  mut open : Int32
  mut serial : Int32
  fail_on : String
  table : String
}

///|
fn revision_driver(
  fail_on~ : String = "",
  table~ : String = "moonorm_revisions",
) -> RevisionDriver {
  { ids: [], log: [], open: 0, serial: 0, fail_on, table, }
}

///|
pub impl @moondb.Driver for RevisionDriver with fn execute(self, sql, params) {
  if self.fail_on != "" && sql.contains(self.fail_on) {
    raise @moondb.QueryError("refused by the test driver: " + sql)
  }
  if sql.has_prefix("INSERT INTO " + self.table) {
    self.ids.push(
      match params[0] {
        @moondb.Text(id) => id
        _ => ""
      },
    )
  } else if sql.has_prefix("DELETE FROM " + self.table) {
    let gone = match params[0] {
      @moondb.Text(id) => id
      _ => ""
    }
    self.ids = self.ids.filter(id => id != gone)
  }
  self.log.push((sql, self.open))
  { rows_affected: 1, last_insert_id: 0, }
}

///|
pub impl @moondb.Driver for RevisionDriver with fn query(self, sql, _params) {
  if sql.contains("SELECT id FROM " + self.table) {
    self.log.push((sql, self.open))
    self.ids.map(id => { columns: ["id"], values: [@moondb.Text(id)], })
  } else {
    []
  }
}

///|
pub impl @moondb.Driver for RevisionDriver with fn begin(self) -> Unit raise @moondb.DbError {
  self.serial = self.serial + 1
  self.open = self.serial
}

///|
pub impl @moondb.Driver for RevisionDriver with fn commit(self) -> Unit raise @moondb.DbError {
  self.open = 0
}

///|
pub impl @moondb.Driver for RevisionDriver with fn rollback(self) -> Unit raise @moondb.DbError {
  self.open = 0
}

///|
pub impl @moondb.Driver for RevisionDriver with fn close(_self) -> Unit {

}

///|
pub extend RevisionDriver with @moondb.Driver::{
  execute,
  begin,
  ping,
  close,
  query_stream,
  commit,
  query,
  rollback,
}

///|
/// A revision that creates the table named after it, so a rendered statement names the
/// revision it came from and the log is readable.
fn table_revision(
  id : String,
  parents : Array[String],
  name~ : String,
) -> Revision {
  let columns = [
    @schema.column("id", IntType, primary_key=true),
    @schema.column("name", TextType),
  ]
  Revision::new(id~, parents~, name~, up=[create_table(id, columns)], down=[
    drop_table(id),
  ])
}

///|
/// 0001 -> 0002 -> 0003.
fn linear_revisions() -> Array[Revision] {
  [
    table_revision("0001", [], name="create heroes"),
    table_revision("0002", ["0001"], name="create teams"),
    table_revision("0003", ["0002"], name="create powers"),
  ]
}

///|
/// Where `id` sits in `ids`, or -1.
fn position_of(ids : Array[String], id : String) -> Int32 {
  for i in 0..<ids.length() {
    if ids[i] == id {
      return i
    }
  }
  -1
}

///|
/// A branch: 0002 and 0004 both follow 0001, and 0005 merges them.
fn branched_revisions() -> Array[Revision] {
  [
    table_revision("0001", [], name="create heroes"),
    table_revision("0002", ["0001"], name="create teams"),
    table_revision("0003", ["0002"], name="create powers"),
    table_revision("0004", ["0001"], name="create cities"),
    table_revision("0005", ["0003", "0004"], name="merge"),
  ]
}

///|
test "revision order follows parents, not the order they were declared in" {
  let shuffled = [
    table_revision("0003", ["0002"], name="third"),
    table_revision("0001", [], name="first"),
    table_revision("0002", ["0001"], name="second"),
  ]
  assert_eq(Revision::order(shuffled), ["0001", "0002", "0003"])
}

///|
test "revision order refuses a duplicate id, an unknown parent, and a cycle" {
  let duplicate = [
    table_revision("0001", [], name="a"),
    table_revision("0001", [], name="b"),
  ]
  let dup = try {
    Revision::order(duplicate) |> ignore
    false
  } catch {
    @moondb.QueryError(message) => message.contains("duplicate")
    _ => false
  }
  assert_eq(dup, true)
  let orphan = [table_revision("0002", ["0001"], name="dangling")]
  let bad_parent = try {
    Revision::order(orphan) |> ignore
    false
  } catch {
    @moondb.QueryError(message) => message.contains("does not exist")
    _ => false
  }
  assert_eq(bad_parent, true)
  let cycle = [
    table_revision("a", ["b"], name="a"),
    table_revision("b", ["a"], name="b"),
  ]
  let looped = try {
    Revision::order(cycle) |> ignore
    false
  } catch {
    @moondb.QueryError(message) => message.contains("cycle")
    _ => false
  }
  assert_eq(looped, true)
}

///|
test "heads and bases of a branched history" {
  assert_eq(revision_heads(linear_revisions()), ["0003"])
  assert_eq(revision_bases(linear_revisions()), ["0001"])
  assert_eq(revision_heads(branched_revisions()), ["0005"])
  let forked = branched_revisions()[:4].to_owned()
  assert_eq(revision_heads(forked), ["0003", "0004"])
}

///|
test "pending applies every head, and refuses 'head' when the history has two" {
  let forked = branched_revisions()[:4].to_owned()
  let both = Revision::pending(forked, [], "heads")
  assert_eq(both.length(), 4)
  assert_eq(both[0], "0001")
  let ambiguous = try {
    Revision::pending(forked, [], "head") |> ignore
    false
  } catch {
    @moondb.QueryError(message) => message.contains("heads")
    _ => false
  }
  assert_eq(ambiguous, true)
  assert_eq(Revision::pending(forked, [], "0004"), ["0001", "0004"])
}

///|
test "pending resumes from whatever is already applied" {
  let all = linear_revisions()
  assert_eq(Revision::pending(all, [], "head"), ["0001", "0002", "0003"])
  assert_eq(Revision::pending(all, ["0001"], "head"), ["0002", "0003"])
  assert_eq(Revision::pending(all, ["0001", "0002", "0003"], "head"), [])
  assert_eq(Revision::pending(all, [], "base"), [])
}

///|
test "a merge revision is applied only after both branches" {
  let order = Revision::order(branched_revisions())
  assert_eq(order[0], "0001")
  assert_eq(order[order.length() - 1], "0005")
  let merge_at = position_of(order, "0005")
  let left_at = position_of(order, "0003")
  let right_at = position_of(order, "0004")
  assert_eq(merge_at > left_at && merge_at > right_at, true)
}

///|
test "doomed unwinds descendants first and keeps the target's ancestors" {
  let all = linear_revisions()
  let applied = ["0001", "0002", "0003"]
  assert_eq(Revision::doomed(all, applied, "base"), ["0003", "0002", "0001"])
  assert_eq(Revision::doomed(all, applied, "0001"), ["0003", "0002"])
  assert_eq(Revision::doomed(all, applied, "head"), [])
}

///|
test "doomed on a branch only unwinds the branch being abandoned" {
  let all = branched_revisions()
  let applied = ["0001", "0002", "0003", "0004"]
  // Going back to 0003 keeps 0001, 0002 and 0003, so only 0004 comes off.
  assert_eq(Revision::doomed(all, applied, "0003"), ["0004"])
  assert_eq(Revision::doomed(all, applied, "0001"), ["0004", "0003", "0002"])
}

///|
test "history is newest first and marks what is applied" {
  let entries = Revision::history(linear_revisions(), ["0001", "0002"])
  assert_eq(entries.length(), 3)
  assert_eq(entries[0].id, "0003")
  assert_eq(entries[0].applied, false)
  assert_eq(entries[1].id, "0002")
  assert_eq(entries[1].applied, true)
  assert_eq(entries[2].parents, [])
}

///|
test "upgrade applies each revision and records it in the same transaction" {
  let drv = revision_driver()
  let sess = @session.Session::new(drv)
  let mig = Migrator::new()
  let applied = mig.upgrade(sess, linear_revisions())
  assert_eq(applied, ["0001", "0002", "0003"])
  assert_eq(mig.heads(sess, linear_revisions()), ["0003"])
  // Every step is one transaction: the CREATE and its bookkeeping INSERT share a
  // transaction number, and no two steps share one.
  let steps = drv.log.filter(entry => {
    entry.0.has_prefix("CREATE TABLE 000") ||
    entry.0.has_prefix("INSERT INTO moonorm_revisions")
  })
  assert_eq(steps.length(), 6)
  assert_eq(steps[0].1 == steps[1].1, true)
  assert_eq(steps[1].1 != steps[2].1, true)
  assert_eq(steps[4].1 == steps[5].1, true)
}

///|
test "a second upgrade applies nothing" {
  let drv = revision_driver()
  let sess = @session.Session::new(drv)
  let mig = Migrator::new()
  mig.upgrade(sess, linear_revisions()) |> ignore
  drv.log.clear()
  assert_eq(mig.upgrade(sess, linear_revisions()), [])
  assert_eq(
    drv.log.filter(entry => entry.0.has_prefix("CREATE TABLE 000")).length(),
    0,
  )
}

///|
test "upgrade resumes from the revisions already applied" {
  let drv = revision_driver()
  drv.ids = ["0001"]
  let sess = @session.Session::new(drv)
  let mig = Migrator::new()
  assert_eq(mig.upgrade(sess, linear_revisions()), ["0002", "0003"])
  assert_eq(drv.ids, ["0001", "0002", "0003"])
}

///|
test "downgrade undoes descendants first and forgets them" {
  let drv = revision_driver()
  let sess = @session.Session::new(drv)
  let mig = Migrator::new()
  mig.upgrade(sess, linear_revisions()) |> ignore
  drv.log.clear()
  assert_eq(mig.downgrade(sess, linear_revisions(), target="0001"), [
    "0003", "0002",
  ])
  assert_eq(drv.ids, ["0001"])
  let drops = drv.log.filter(entry => entry.0.has_prefix("DROP TABLE"))
  assert_eq(drops.map(entry => entry.0), ["DROP TABLE 0003", "DROP TABLE 0002"])
}

///|
test "a failing step stops the run and leaves the earlier revisions applied" {
  let drv = revision_driver(fail_on="CREATE TABLE 0002")
  let sess = @session.Session::new(drv)
  let mig = Migrator::new()
  let outcome = try {
    mig.upgrade(sess, linear_revisions()) |> ignore
    false
  } catch {
    @moondb.QueryError(_) => true
    _ => false
  }
  assert_eq(outcome, true)
  assert_eq(drv.ids, ["0001"])
}

///|
test "stamp records a revision without running any operation" {
  let drv = revision_driver()
  let sess = @session.Session::new(drv)
  let mig = Migrator::new()
  mig.stamp(sess, linear_revisions()) |> ignore
  assert_eq(drv.ids, ["0001", "0002", "0003"])
  assert_eq(
    drv.log.filter(entry => entry.0.has_prefix("CREATE TABLE 000")).length(),
    0,
  )
  // Stamping back to a revision keeps its ancestors and forgets the rest.
  mig.stamp(sess, linear_revisions(), target="0002") |> ignore
  assert_eq(drv.ids, ["0001", "0002"])
}

///|
test "history through the migrator reports what the database has" {
  let drv = revision_driver()
  let sess = @session.Session::new(drv)
  let mig = Migrator::new()
  mig.upgrade(sess, linear_revisions(), target="0002") |> ignore
  let entries = mig.history(sess, linear_revisions())
  assert_eq(entries.map(entry => entry.applied), [false, true, true])
}

///|
test "the offline plan is the statements the online run executes" {
  let drv = revision_driver()
  let sess = @session.Session::new(drv)
  let mig = Migrator::new()
  mig.upgrade(sess, linear_revisions()) |> ignore
  let online = drv.log
    .filter(entry => {
      entry.0.has_prefix("CREATE TABLE 000") ||
      entry.0.has_prefix("INSERT INTO moonorm_revisions")
    })
    .map(entry => entry.0)
  let plan = mig.upgrade_sql(linear_revisions(), [])
  let offline : Array[String] = []
  for step in plan {
    for statement in step.statements {
      offline.push(statement.sql)
    }
  }
  assert_eq(offline, online)
}

///|
test "upgrade_sql renders for the dialect it is asked for" {
  let mig = Migrator::new()
  let step = mig.upgrade_sql(linear_revisions(), [], dialect=Postgres)[0]
  assert_eq(step.id, "0001")
  assert_eq(
    step.statements[0].sql,
    "CREATE TABLE 0001 (id INTEGER PRIMARY KEY, name TEXT)",
  )
  assert_eq(
    step.statements[1].sql,
    "INSERT INTO moonorm_revisions (id, name) VALUES (?, ?)",
  )
  assert_eq(step.statements[1].params, [
    @moondb.Text("0001"),
    @moondb.Text("create heroes"),
  ])
  assert_eq(step.statements[0].sql.contains("INTEGER"), true)
}

///|
test "an unknown target is refused before anything runs" {
  let drv = revision_driver()
  let sess = @session.Session::new(drv)
  let mig = Migrator::new()
  let refused = try {
    mig.upgrade(sess, linear_revisions(), target="9999") |> ignore
    false
  } catch {
    @moondb.QueryError(message) => message.contains("unknown revision")
    _ => false
  }
  assert_eq(refused, true)
  assert_eq(
    drv.log.filter(entry => entry.0.has_prefix("CREATE TABLE 000")).length(),
    0,
  )
}

///|
test "a custom revisions table is used for bookkeeping" {
  let drv = revision_driver(table="alembic_version")
  let sess = @session.Session::new(drv)
  let mig = Migrator::new(revisions_table="alembic_version")
  assert_eq(mig.upgrade(sess, linear_revisions()), ["0001", "0002", "0003"])
  assert_eq(drv.ids, ["0001", "0002", "0003"])
  assert_eq(
    drv.log.filter(entry => entry.0.contains("alembic_version")).length() > 0,
    true,
  )
}
