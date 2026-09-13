// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The deferred DoD, made real: published moonorm + published moonsqlite, driven
// against a genuine SQLite file (not :memory:, not the MockDriver). One test walks
// the whole stack — versioned migrations up, a Session doing CRUD through a declared
// Model, a CTE + IN-subquery SELECT, an optimistic-locked update that both succeeds
// and then catches a stale write, and migrations down. Every step is asserted, so a
// regression anywhere in the published chain turns this red.

///|
priv struct Team {
  id : Int
  name : String
}

///|
priv struct Hero {
  id : Int
  name : String
  team_id : Int
  version : Int
}

///|
/// The team model: id + name, id being the rowid primary key.
fn team_model() -> @orm.Model[Team] {
  @orm.Model::new(
    "team",
    [
      @orm.column("id", @orm.IntType, primary_key=true),
      @orm.column("name", @orm.TextType, nullable=false),
    ],
    r => { id: r.int(0), name: r.text(1), },
    t => [("id", @moondb.Int(t.id)), ("name", @moondb.Text(t.name))],
  )
}

///|
/// The hero model, with a foreign key to team and a version column for optimistic
/// locking.
fn hero_model() -> @orm.Model[Hero] {
  @orm.Model::new(
    "hero",
    [
      @orm.column("id", @orm.IntType, primary_key=true),
      @orm.column("name", @orm.TextType, nullable=false),
      @orm.column("team_id", @orm.IntType, references=Some(("team", "id"))),
      @orm.column("version", @orm.IntType, nullable=false),
    ],
    r => {
      id: r.int(0),
      name: r.text(1),
      team_id: r.int(2),
      version: r.int(3),
    },
    h => {
      [
        ("id", @moondb.Int(h.id)),
        ("name", @moondb.Text(h.name)),
        ("team_id", @moondb.Int(h.team_id)),
        ("version", @moondb.Int(h.version)),
      ]
    },
  )
}

///|
/// The migration set: create team, then hero, then an index on hero.team_id.
fn migrations() -> Array[@orm.Migration] {
  [
    {
      version: 1,
      name: "create_team",
      up: ["CREATE TABLE team (id INTEGER PRIMARY KEY, name TEXT NOT NULL)"],
      down: ["DROP TABLE team"],
    },
    {
      version: 2,
      name: "create_hero",
      up: [
        "CREATE TABLE hero (id INTEGER PRIMARY KEY, name TEXT NOT NULL, team_id INTEGER REFERENCES team(id), version INTEGER NOT NULL)",
      ],
      down: ["DROP TABLE hero"],
    },
    {
      version: 3,
      name: "index_hero_team",
      up: ["CREATE INDEX ix_hero_team ON hero (team_id)"],
      down: ["DROP INDEX ix_hero_team"],
    },
  ]
}

///|
test "e2e: migrations, Session CRUD, CTE select, optimistic lock on real SQLite" {
  let path = ".moonorm_e2e.db"
  // Start from a clean slate so the run is deterministic across CI re-runs.
  let setup = @sqlite.SqliteDriver::open(path)
  setup.exec_script(
    "DROP TABLE IF EXISTS hero; DROP TABLE IF EXISTS team; DROP TABLE IF EXISTS schema_migrations;",
  )
  setup.close()
  let db = @sqlite.SqliteDriver::open(path)
  let sess = @orm.Session::new(db)

  // --- migrations up -------------------------------------------------------
  let migrator = @orm.Migrator::new()
  let applied = migrator.up(sess, migrations())
  assert_eq(applied, 3)
  assert_eq(migrator.current_version(sess), 3)
  assert_eq(migrator.applied_versions(sess), [1, 2, 3])
  // Re-running is a no-op: nothing pending.
  assert_eq(migrator.up(sess, migrations()), 0)

  // --- Session CRUD through the models ------------------------------------
  let teams = team_model()
  let heroes = hero_model()
  sess.insert_record(teams, { id: 1, name: "avengers", }) |> ignore
  sess.insert_record(teams, { id: 2, name: "x-men", }) |> ignore
  sess.insert_record(heroes, { id: 1, name: "ironman", team_id: 1, version: 1, })
  |> ignore
  sess.insert_record(heroes, { id: 2, name: "hulk", team_id: 1, version: 1, })
  |> ignore
  sess.insert_record(heroes, {
    id: 3,
    name: "wolverine",
    team_id: 2,
    version: 1,
  })
  |> ignore
  let all_heroes = sess.all(heroes)
  assert_eq(all_heroes.length(), 3)
  // fetch_as with a refined Select decodes rows into records.
  let avengers = sess.fetch_as(
    heroes,
    heroes.select().eq("team_id", @moondb.Int(1)).order_by("id", @orm.Asc),
  )
  assert_eq(avengers.length(), 2)
  assert_eq(avengers[0].name, "ironman")
  assert_eq(avengers[1].name, "hulk")

  // --- CTE + IN-subquery ---------------------------------------------------
  // Teams that have at least one hero, via a CTE feeding an IN subquery.
  let with_heroes = @orm.select("team")
    .column("name")
    .with_cte("teamed", @orm.select("hero").column("team_id"))
    .where_in("id", @orm.select("teamed").column("team_id"))
    .order_by("name", @orm.Asc)
  let rows = sess.fetch(with_heroes)
  assert_eq(rows.length(), 2)
  assert_eq(rows[0].text(0), "avengers")
  assert_eq(rows[1].text(0), "x-men")

  // --- optimistic lock -----------------------------------------------------
  // Bump ironman from version 1 -> 2, guarded on the current version.
  let ok = sess.modify_versioned(
    @orm.update("hero")
    .set("name", @moondb.Text("iron man"))
    .set("version", @moondb.Int(2))
    .where_("id", "=", @moondb.Int(1))
    .where_("version", "=", @moondb.Int(1)),
  )
  assert_eq(ok.rows_affected, 1L)
  // A second update still guarded on version 1 must find no row (it is 2 now) and
  // raise LostUpdate rather than silently updating nothing.
  let stale = try {
    sess.modify_versioned(
      @orm.update("hero")
      .set("name", @moondb.Text("stale"))
      .set("version", @moondb.Int(3))
      .where_("id", "=", @moondb.Int(1))
      .where_("version", "=", @moondb.Int(1)),
    )
    |> ignore
    false
  } catch {
    @orm.LostUpdate(_) => true
    _ => false
  }
  assert_eq(stale, true)
  // The winning update stuck; the stale one changed nothing.
  let iron = sess.fetch_as(heroes, heroes.select().eq("id", @moondb.Int(1)))
  assert_eq(iron[0].name, "iron man")
  assert_eq(iron[0].version, 2)

  // --- N+1-avoiding batch load --------------------------------------------
  // Load every team's heroes in one IN query and check the grouping lands on the
  // real backend: avengers (id 1) has two heroes, x-men (id 2) has one.
  let teams_all = sess.all(teams)
  assert_eq(teams_all.length(), 2)
  let children : @orm.Relation[Team, Hero] = @orm.has_many(heroes, "team_id", (
    t : Team,
  ) => @moondb.Int(t.id))
  let by_team = sess.load_batch(teams_all, children)
  assert_eq(by_team.length(), 2)
  assert_eq(by_team[0].length(), 2) // avengers
  assert_eq(by_team[1].length(), 1) // x-men
  assert_eq(by_team[1][0].name, "wolverine")
  // The N:1 direction, batched: each hero resolves to its team in one query.
  let all_heroes2 = sess.all(heroes)
  let parent : @orm.Relation[Hero, Team] = @orm.belongs_to(teams, "id", (
    h : Hero,
  ) => @moondb.Int(h.team_id))
  let teams_of = sess.load_one_batch(all_heroes2, parent)
  assert_eq(teams_of.length(), 3)
  for t in teams_of {
    assert_eq(t is Some(_), true)
  }

  // --- migrations down -----------------------------------------------------
  let rolled = migrator.down_to(sess, migrations(), 0)
  assert_eq(rolled, 3)
  assert_eq(migrator.current_version(sess), 0)
  // hero is gone: querying it now errors at the engine.
  let gone = try {
    sess.query("SELECT * FROM hero", []) |> ignore
    false
  } catch {
    @moondb.QueryError(_) => true
    _ => false
  }
  assert_eq(gone, true)
  sess.close()
}
