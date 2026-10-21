///|
struct Member {
  id : Int32
  name : String
  squad_id : Int32
} derive(Eq, Debug)

///|
fn member_model() -> @schema.Model[Member] {
  @schema.Model::new(
    "members",
    [
      @schema.column("id", IntType, primary_key=true),
      @schema.column("name", TextType, nullable=false),
      @schema.column("squad_id", IntType, references=("squads", "id")),
    ],
    r => { id: r.int(0), name: r.text(1), squad_id: r.int(2), },
    m => {
      [("id", Int(m.id)), ("name", Text(m.name)), ("squad_id", Int(m.squad_id))]
    },
  )
}

///|
pub extend Member with Debug::{to_repr}

///|
pub extend Member with Eq::{not_equal, equal}

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
  let logs = @schema.Model::new(
    "logs",
    [@schema.column("msg", TextType, nullable=false)],
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
  let grants = @schema.Model::new(
    "grants",
    [
      @schema.column("user_id", IntType, primary_key=true),
      @schema.column("role", TextType, primary_key=true),
    ],
    r => (r.int(0), r.text(1)),
    (g : (Int32, String)) => [("user_id", Int(g.0)), ("role", Text(g.1))],
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
