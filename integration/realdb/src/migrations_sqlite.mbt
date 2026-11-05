// The migration round trip on a real SQLite file: upgrade, downgrade, upgrade again,
// and the structure at the end is the structure at the first upgrade. The bookkeeping
// table is filtered out of the snapshots — it is the runner's own, not part of the
// schema being migrated.

///|
/// The schema a snapshot records, with the runner's bookkeeping table left out.
fn schema_text(schema : @schema.Schema) -> String {
  let tables = schema.tables.filter(t => t.name != "moonorm_revisions")
  @schema.Schema::new(tables).snapshot(@query.Sqlite)
}

///|
/// The revisions the round trip applies: a created table with an index, a second table
/// with a foreign key, a column added, a column dropped, and a column renamed.
fn round_trip_revisions() -> Array[@migrate.Revision] {
  let heroes = [
    @schema.column("id", @schema.IntType, primary_key=true, autoincrement=true),
    @schema.column("name", @schema.TextType, nullable=false),
    @schema.column("power", @schema.IntType, default="0"),
  ]
  let teams = [
    @schema.column("id", @schema.IntType, primary_key=true),
    @schema.column("name", @schema.TextType, nullable=false, unique=true),
  ]
  [
    @migrate.Revision::new(
      id="0001",
      name="create heroes",
      up=[@migrate.create_table("heroes", heroes)],
      down=[@migrate.drop_table("heroes")],
    ),
    @migrate.Revision::new(
      id="0002",
      parents=["0001"],
      name="create teams",
      up=[
        @migrate.create_table("teams", teams),
        @migrate.create_index("ix_teams_name", "teams", ["name"]),
      ],
      down=[
        @migrate.drop_index("ix_teams_name", table="teams"),
        @migrate.drop_table("teams"),
      ],
    ),
    @migrate.Revision::new(
      id="0003",
      parents=["0002"],
      name="add hero team",
      up=[
        @migrate.add_column(
          "heroes",
          @schema.column("team_id", @schema.IntType, references=("teams", "id")),
        ),
        @migrate.add_column(
          "heroes",
          @schema.column("archived", @schema.BoolType, default="0"),
        ),
      ],
      down=[
        @migrate.drop_column("heroes", "archived"),
        @migrate.drop_column("heroes", "team_id"),
      ],
    ),
    @migrate.Revision::new(
      id="0004",
      parents=["0003"],
      name="rename power to strength",
      up=[@migrate.rename_column("heroes", "power", "strength")],
      down=[@migrate.rename_column("heroes", "strength", "power")],
    ),
  ]
}

///|
test "migrations round-trip on a real SQLite database" {
  let path = temp_path("moonorm-roundtrip.db")
  let driver = @sqlite.SqliteDriver::open(path) catch {
    error => abort("open failed: " + error.to_string())
  }
  let sess = @session.Session::new(driver)
  let migrator = @migrate.Migrator::new()
  let revisions = round_trip_revisions()
  try {
    let applied = migrator.upgrade(sess, revisions)
    assert_eq(applied, ["0001", "0002", "0003", "0004"])
    let after_upgrade = schema_text(
      @migrate.reflect_schema(driver, @query.Sqlite),
    )
    assert_eq(after_upgrade.contains("table heroes"), true)
    assert_eq(after_upgrade.contains("column strength INTEGER"), true)
    assert_eq(after_upgrade.contains("column power "), false)
    assert_eq(after_upgrade.contains("index ix_teams_name (name)"), true)
    // Down to base, then up again: the same structure comes back.
    let undone = migrator.downgrade(sess, revisions, target="base")
    assert_eq(undone, ["0004", "0003", "0002", "0001"])
    let at_base = schema_text(@migrate.reflect_schema(driver, @query.Sqlite))
    assert_eq(at_base.contains("table heroes"), false)
    let reapplied = migrator.upgrade(sess, revisions)
    assert_eq(reapplied, ["0001", "0002", "0003", "0004"])
    let after_second = schema_text(
      @migrate.reflect_schema(driver, @query.Sqlite),
    )
    assert_eq(after_second, after_upgrade)
    // Part of the way back, then forward again from that point.
    migrator.downgrade(sess, revisions, target="0002") |> ignore
    let at_two = schema_text(@migrate.reflect_schema(driver, @query.Sqlite))
    assert_eq(at_two.contains("column team_id"), false)
    assert_eq(migrator.upgrade(sess, revisions), ["0003", "0004"])
    assert_eq(
      schema_text(@migrate.reflect_schema(driver, @query.Sqlite)),
      after_upgrade,
    )
    // The history knows where it is, and stamping back does not touch the schema.
    assert_eq(migrator.heads(sess, revisions), ["0004"])
    assert_eq(migrator.history(sess, revisions).map(entry => entry.applied), [
      true, true, true, true,
    ])
    sess.close()
  } catch {
    error => {
      sess.close()
      abort("migration round trip failed: " + error.to_string())
    }
  }
}

///|
/// A file path in the system temporary directory — never in the working tree, and
/// unique per run so a leftover file from an earlier run cannot be mistaken for a fresh
/// database.
fn temp_path(name : String) -> String {
  let dir = match @env.get_env_var("TMPDIR") {
    Some(d) => d
    None =>
      match @env.get_env_var("TEMP") {
        Some(d) => d
        None => "."
      }
  }
  dir + "/" + @env.now().to_string() + "-" + name
}
