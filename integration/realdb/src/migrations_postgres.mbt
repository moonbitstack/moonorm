// The migration round trip on a real PostgreSQL server. The plan is the migrator's
// own — `upgrade_sql` returns exactly the statements `upgrade` executes — and this test
// runs it over the async wire driver, one revision per transaction, then reflects the
// schema with the library's own query texts and parsers.
//
// Gated on `MOONORM_LIVE`: with it set (CI does), the server must be reachable and a
// failure to connect is a test failure. Without it, the test returns immediately so a
// local checkout with no database still runs the rest of the suite.

///|
fn env_or(key : String, fallback : String) -> String {
  match @env.get_env_var(key) {
    Some(value) => if value == "" { fallback } else { value }
    None => fallback
  }
}

///|
fn env_port(key : String, fallback : Int32) -> Int32 {
  let text = env_or(key, fallback.to_string())
  let mut value = 0
  let mut digits = true
  for i in 0..<text.length() {
    let c = text[i].to_int()
    if c < 48 || c > 57 {
      digits = false
    } else {
      value = value * 10 + (c - 48)
    }
  }
  if digits {
    value
  } else {
    fallback
  }
}

///|
fn live() -> Bool {
  @env.get_env_var("MOONORM_LIVE") is Some(_)
}

///|
/// The schema as PostgreSQL reports it, with the runner's bookkeeping table left out.
async fn pg_schema(conn : @pg.PgConn) -> @schema.Schema {
  let names = @migrate.table_names_of(
    conn.query(@migrate.postgres_tables_query(), []),
  )
  let all_indexes = @migrate.indexes_of_rows(
    conn.query(@migrate.postgres_indexes_query(), []),
  )
  let tables : Array[@schema.TableSpec] = []
  for name in names {
    if name == "moonorm_revisions" {
      continue
    }
    let columns = @migrate.reflect_columns_pg(
      conn.query(@migrate.postgres_columns_query(), [@moondb.Text(name)]),
    )
    let indexes = all_indexes
      .filter(ix => ix.table == name)
      .map(ix => @schema.index(ix.columns, name=ix.name, unique=ix.unique))
    tables.push({ name, columns, indexes, })
  }
  @schema.Schema::new(tables)
}

///|
/// A revision set that every engine here can express: tables, an index, a column added,
/// a column dropped, and a column renamed. No operation that one engine cannot do.
fn portable_revisions() -> Array[@migrate.Revision] {
  let heroes = [
    @schema.column("id", @schema.IntType, primary_key=true),
    @schema.column("name", @schema.TextType, nullable=false),
    @schema.column("power", @schema.IntType),
  ]
  let teams = [
    @schema.column("id", @schema.IntType, primary_key=true),
    // MySQL cannot index a bare TEXT column, so the indexed one is a VARCHAR —
    // the same declaration works on all three engines.
    @schema.column("name", @schema.VarcharType(255), nullable=false),
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
          @schema.column("team_id", @schema.IntType),
        ),
      ],
      down=[@migrate.drop_column("heroes", "team_id")],
    ),
    @migrate.Revision::new(
      id="0004",
      parents=["0003"],
      name="rename power",
      up=[@migrate.rename_column("heroes", "power", "strength")],
      down=[@migrate.rename_column("heroes", "strength", "power")],
    ),
  ]
}

///|
/// Run a plan, one step per transaction, exactly as `Migrator::upgrade` does over a
/// synchronous driver.
async fn run_steps(conn : @pg.PgConn, steps : Array[@migrate.Step]) -> Unit {
  for step in steps {
    conn.begin()
    for statement in step.statements {
      conn.execute(statement.sql, statement.params) |> ignore
    }
    conn.commit()
  }
}

///|
async test "revision migrations round-trip on a real PostgreSQL server" {
  guard live() else { return }
  let conn = @pg.PgConn::connect(
    env_or("PGHOST", "127.0.0.1"),
    env_port("PGPORT", 5432),
    env_or("PGUSER", "orm"),
    env_or("PGPASSWORD", "pw"),
    env_or("PGDATABASE", "orm"),
  )
  let migrator = @migrate.Migrator::new()
  let revisions = portable_revisions()
  defer conn.close()
  // A clean slate: the tables this test owns, and nothing else.
  conn.execute(
    "DROP TABLE IF EXISTS heroes, teams, moonorm_revisions CASCADE",
    [],
  )
  |> ignore
  conn.execute(@migrate.revisions_table_sql("moonorm_revisions"), []) |> ignore
  // Upgrade, and snapshot what the server actually holds.
  let up = migrator.upgrade_sql(
    revisions,
    [],
    target="heads",
    dialect=@query.Postgres,
  )
  assert_eq(up.length(), 4)
  run_steps(conn, up)
  let after_upgrade = pg_schema(conn).snapshot(@query.Postgres)
  assert_eq(after_upgrade.contains("table heroes"), true)
  assert_eq(after_upgrade.contains("column strength INTEGER"), true)
  assert_eq(after_upgrade.contains("index ix_teams_name (name)"), true)
  // Where the runner thinks it is, read back off its own table.
  let applied = @migrate.table_names_of(
    conn.query("SELECT id FROM moonorm_revisions ORDER BY id", []),
  )
  assert_eq(applied, ["0001", "0002", "0003", "0004"])
  // Down to base, then up again: the structure has to come back identical.
  let down = migrator.downgrade_sql(
    revisions,
    applied,
    target="base",
    dialect=@query.Postgres,
  )
  assert_eq(down.length(), 4)
  run_steps(conn, down)
  let at_base = pg_schema(conn).snapshot(@query.Postgres)
  assert_eq(at_base.contains("table heroes"), false)
  run_steps(conn, up)
  let after_second = pg_schema(conn).snapshot(@query.Postgres)
  assert_eq(after_second, after_upgrade)
}

///|
/// Autogenerate against the live server: a declared schema that matches the database
/// produces nothing, and one that has drifted produces exactly the operations that
/// close the gap.
async test "autogenerate reads a real PostgreSQL schema" {
  guard live() else { return }
  let conn = @pg.PgConn::connect(
    env_or("PGHOST", "127.0.0.1"),
    env_port("PGPORT", 5432),
    env_or("PGUSER", "orm"),
    env_or("PGPASSWORD", "pw"),
    env_or("PGDATABASE", "orm"),
  )
  defer conn.close()
  // A clean slate first: this test reads the whole schema, so a table left by
  // an earlier run would read as a table the models dropped.
  conn.execute(
    "DROP TABLE IF EXISTS heroes, teams, shapes, moonorm_revisions",
    [],
  )
  |> ignore
  conn.execute(
    "CREATE TABLE shapes (id INTEGER PRIMARY KEY, name TEXT NOT NULL, size INTEGER)",
    [],
  )
  |> ignore
  let live_schema = pg_schema(conn).tables
  let shapes = match live_schema.iter().find_first(t => t.name == "shapes") {
    Some(table) => table
    None => abort("the shapes table was not reflected")
  }
  // No difference against itself.
  assert_eq(
    @migrate.autogenerate([shapes], live_schema, dialect=@query.Postgres).length(),
    0,
  )
  // A declared column the database lacks, and a database column the model dropped.
  let drifted = @schema.TableSpec::new("shapes", [
    @schema.column("id", @schema.IntType, primary_key=true),
    @schema.column("name", @schema.TextType, nullable=false),
    @schema.column("weight", @schema.IntType),
  ])
  let ops = @migrate.autogenerate(
    [drifted],
    live_schema,
    dialect=@query.Postgres,
  )
  assert_eq(ops.map(op => op.to_sql(@query.Postgres)[0]), [
    "ALTER TABLE shapes ADD COLUMN weight INTEGER", "ALTER TABLE shapes DROP COLUMN size",
  ])
  conn.execute("DROP TABLE shapes", []) |> ignore
}
