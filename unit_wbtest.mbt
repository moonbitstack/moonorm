// Unit-of-work coverage: the identity map, the pending/dirty/deleted queues, and the
// order a flush emits them in. These run on `@moondb.MockDriver` like the rest of the
// suite, through a tap that keeps the SQL text: the mock never parses the statements
// it is handed and so cannot report them, and "exactly one INSERT", "parent first"
// and "the DELETE" are claims about the text and its order.

///|
/// A `@moondb.MockDriver` with a statement log. Everything is delegated, so the echo
/// store, the row shape and the transaction bracket stay exactly the mock's; the only
/// addition is the SQL going past.
struct Tap {
  inner : @moondb.MockDriver
  sql : Array[String]
}

///|
fn Tap::new() -> Tap {
  { inner: @moondb.MockDriver::new(), sql: [], }
}

///|
impl @moondb.Driver for Tap with fn execute(
  self : Tap,
  sql : String,
  params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  self.sql.push(sql)
  self.inner.execute(sql, params)
}

///|
impl @moondb.Driver for Tap with fn query(
  self : Tap,
  sql : String,
  params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.sql.push(sql)
  self.inner.query(sql, params)
}

///|
impl @moondb.Driver for Tap with fn begin(self : Tap) -> Unit raise @moondb.DbError {
  self.inner.begin()
}

///|
impl @moondb.Driver for Tap with fn commit(self : Tap) -> Unit raise @moondb.DbError {
  self.inner.commit()
}

///|
impl @moondb.Driver for Tap with fn rollback(self : Tap) -> Unit raise @moondb.DbError {
  self.inner.rollback()
}

///|
impl @moondb.Driver for Tap with fn close(self : Tap) -> Unit {
  self.inner.close()
}

///|
/// `name` is mutable so a test can prove two `get`s handed back one instance without
/// leaning on `physical_equal`, whose result the compiler does not promise to keep
/// stable across backends.
struct Squad {
  id : Int
  mut name : String
} derive(Eq, Debug)

///|
struct Member {
  id : Int
  name : String
  squad_id : Int
} derive(Eq, Debug)

///|
fn squad_model() -> Model[Squad] {
  Model::new(
    "squads",
    [
      column("id", IntType, primary_key=true),
      column("name", TextType, nullable=false),
    ],
    r => { id: r.int(0), name: r.text(1), },
    s => [("id", Int(s.id)), ("name", Text(s.name))],
  )
}

///|
fn member_model() -> Model[Member] {
  Model::new(
    "members",
    [
      column("id", IntType, primary_key=true),
      column("name", TextType, nullable=false),
      column("squad_id", IntType, references=("squads", "id")),
    ],
    r => { id: r.int(0), name: r.text(1), squad_id: r.int(2), },
    m => {
      [("id", Int(m.id)), ("name", Text(m.name)), ("squad_id", Int(m.squad_id))]
    },
  )
}

///|
test "identity: two gets of the same row return the same instance" {
  let tap = Tap::new()
  let sess = Session::new(tap)
  let squads = squad_model()
  // Seed a row shaped (id, name) so squad_model.from_row decodes it. Seeding goes
  // straight at the mock, so it does not show up in the tap's log.
  tap.inner.execute("seed", [Int(1), Text("avengers")]) |> ignore
  let a = match sess.get(squads, Int(1)) {
    Some(r) => r
    None => fail("row 1 should load")
  }
  let b = match sess.get(squads, Int(1)) {
    Some(r) => r
    None => fail("row 1 should still load")
  }
  assert_eq(physical_equal(a, b), true)
  // The same instance, proven without physical_equal: a write through one is visible
  // through the other.
  a.name = "renamed"
  assert_eq(b.name, "renamed")
  // Only the first get queried; the second was answered by the identity map.
  assert_eq(tap.sql, ["SELECT id, name FROM squads WHERE id = ? LIMIT 1"])
  sess.close()
}

///|
test "identity: expunge drops the record, so the next get reads a fresh one" {
  let tap = Tap::new()
  let sess = Session::new(tap)
  let squads = squad_model()
  tap.inner.execute("seed", [Int(1), Text("avengers")]) |> ignore
  let a = match sess.get(squads, Int(1)) {
    Some(r) => r
    None => fail("row 1 should load")
  }
  a.name = "renamed"
  sess.expunge(squads, a)
  let b = match sess.get(squads, Int(1)) {
    Some(r) => r
    None => fail("row 1 should reload")
  }
  assert_eq(physical_equal(a, b), false)
  assert_eq(b.name, "avengers")
  assert_eq(tap.sql.length(), 2)
  sess.close()
}

///|
test "unit of work: add queues, flush emits one INSERT, record becomes gettable" {
  let tap = Tap::new()
  let sess = Session::new(tap)
  let squads = squad_model()
  sess.add_record(squads, { id: 1, name: "avengers", })
  // Queued, not executed: `add_record` is the deferred half of the pair, unlike
  // `insert_record`.
  assert_eq(sess.pending_count(), 1)
  assert_eq(tap.sql.length(), 0)
  sess.flush()
  assert_eq(tap.sql, ["INSERT INTO squads (id, name) VALUES (?, ?)"])
  assert_eq(sess.pending_count(), 0)
  // Flushing registered the record, so `get` answers from the identity map and no
  // second statement reaches the driver.
  assert_eq(sess.get(squads, Int(1)), Some({ id: 1, name: "avengers", }))
  assert_eq(tap.sql.length(), 1)
  sess.close()
}

///|
test "unit of work: insert_record still executes immediately" {
  let tap = Tap::new()
  let sess = Session::new(tap)
  let squads = squad_model()
  sess.insert_record(squads, { id: 1, name: "avengers", }) |> ignore
  assert_eq(sess.pending_count(), 0)
  assert_eq(tap.sql, ["INSERT INTO squads (id, name) VALUES (?, ?)"])
  sess.close()
}

///|
test "unit of work: a parent and child added together insert parent-first" {
  let tap = Tap::new()
  let sess = Session::new(tap)
  let squads = squad_model()
  let members = member_model()
  // Queued child first on purpose: the flush must reorder on the declared foreign
  // key, not on the order the caller happened to add them in.
  sess.add_record(members, { id: 7, name: "hulk", squad_id: 1, })
  sess.add_record(squads, { id: 1, name: "avengers", })
  sess.flush()
  assert_eq(tap.sql, [
    "INSERT INTO squads (id, name) VALUES (?, ?)", "INSERT INTO members (id, name, squad_id) VALUES (?, ?, ?)",
  ])
  sess.close()
}

///|
test "unit of work: delete queues, flush emits the DELETE keyed on the pk" {
  let tap = Tap::new()
  let sess = Session::new(tap)
  let squads = squad_model()
  sess.delete_record(squads, { id: 1, name: "avengers", })
  assert_eq(sess.deleted_count(), 1)
  assert_eq(tap.sql.length(), 0)
  sess.flush()
  assert_eq(tap.sql, ["DELETE FROM squads WHERE id = ?"])
  assert_eq(sess.deleted_count(), 0)
  sess.close()
}

///|
test "unit of work: deletes run child-first, the reverse of the insert order" {
  let tap = Tap::new()
  let sess = Session::new(tap)
  let squads = squad_model()
  let members = member_model()
  // Queued child first, so passing this needs the reversal to have something to
  // reverse — queue order alone would put the parent first and orphan the child.
  sess.delete_record(members, { id: 7, name: "hulk", squad_id: 1, })
  sess.delete_record(squads, { id: 1, name: "avengers", })
  sess.flush()
  assert_eq(tap.sql, [
    "DELETE FROM members WHERE id = ?", "DELETE FROM squads WHERE id = ?",
  ])
  sess.close()
}

///|
test "unit of work: flush emits inserts, then updates, then deletes" {
  let tap = Tap::new()
  let sess = Session::new(tap)
  let squads = squad_model()
  sess.delete_record(squads, { id: 3, name: "gone", })
  sess.update_record(squads, { id: 2, name: "x-men", })
  sess.add_record(squads, { id: 1, name: "avengers", })
  assert_eq(sess.dirty_count(), 1)
  sess.flush()
  assert_eq(tap.sql, [
    "INSERT INTO squads (id, name) VALUES (?, ?)", "UPDATE squads SET name = ? WHERE id = ?",
    "DELETE FROM squads WHERE id = ?",
  ])
  assert_eq(sess.dirty_count(), 0)
  sess.close()
}

///|
test "unit of work: commit flushes first" {
  let tap = Tap::new()
  let sess = Session::new(tap)
  let squads = squad_model()
  sess.begin()
  sess.add_record(squads, { id: 1, name: "avengers", })
  assert_eq(tap.sql.length(), 0)
  sess.commit()
  assert_eq(tap.sql, ["INSERT INTO squads (id, name) VALUES (?, ?)"])
  assert_eq(sess.pending_count(), 0)
  assert_eq(tap.inner.in_transaction(), false)
  sess.close()
}

///|
test "unit of work: rollback abandons what was queued" {
  let tap = Tap::new()
  let sess = Session::new(tap)
  let squads = squad_model()
  sess.begin()
  sess.add_record(squads, { id: 1, name: "avengers", })
  sess.rollback()
  assert_eq(sess.pending_count(), 0)
  assert_eq(tap.sql.length(), 0)
  sess.close()
}

///|
test "unit of work: a model without a declared primary key cannot be addressed" {
  let sess = Session::new(Tap::new())
  let logs = Model::new(
    "logs",
    [column("msg", TextType, nullable=false)],
    r => r.text(0),
    (m : String) => [("msg", Text(m))],
  )
  let rejected = try {
    sess.get(logs, Int(1)) |> ignore
    ""
  } catch {
    @moondb.QueryError(m) => m
    other => raise other
  }
  assert_eq(rejected, "logs declares no primary key")
  sess.close()
}

///|
test "identity: a composite key round-trips through get_by" {
  let tap = Tap::new()
  let sess = Session::new(tap)
  let grants = Model::new(
    "grants",
    [
      column("user_id", IntType, primary_key=true),
      column("role", TextType, primary_key=true),
    ],
    r => (r.int(0), r.text(1)),
    (g : (Int, String)) => [("user_id", Int(g.0)), ("role", Text(g.1))],
  )
  tap.inner.execute("seed", [Int(7), Text("admin")]) |> ignore
  let a = match sess.get_by(grants, [Int(7), Text("admin")]) {
    Some(g) => g
    None => fail("grant should load")
  }
  assert_eq(a, (7, "admin"))
  sess.get_by(grants, [Int(7), Text("admin")]) |> ignore
  // The second lookup came out of the identity map, so only one SELECT was issued.
  assert_eq(tap.sql, [
    "SELECT user_id, role FROM grants WHERE user_id = ? AND role = ? LIMIT 1",
  ])
  // A key of the wrong width is refused before the query.
  let rejected = try {
    sess.get(grants, Int(7)) |> ignore
    ""
  } catch {
    @moondb.QueryError(m) => m
    other => raise other
  }
  assert_eq(rejected, "grants has a 2-column primary key, given 1")
  sess.close()
}

///|
pub extend Squad with Debug::{to_repr}

///|
pub extend Squad with Eq::{not_equal, equal}

///|
pub extend Member with Debug::{to_repr}

///|
pub extend Member with Eq::{not_equal, equal}
