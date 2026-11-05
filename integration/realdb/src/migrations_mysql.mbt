// The same round trip on a real MySQL server: the plan the migrator renders for MySQL,
// executed one revision per transaction over the async wire driver, then the schema
// reflected back with the library's own query texts.

///|
/// The schema as MySQL reports it, with the runner's bookkeeping table left out.
async fn mysql_schema(conn : @mysql.MysqlConn) -> @schema.Schema {
  let names = @migrate.table_names_of(conn.query(@migrate.mysql_tables_query(), []))
  let all_indexes = @migrate.indexes_of_rows(
    conn.query(@migrate.mysql_indexes_query(), []),
  )
  let tables : Array[@schema.TableSpec] = []
  for name in names {
    if name == "moonorm_revisions" {
      continue
    }
    let columns = @migrate.reflect_columns_mysql(
      conn.query(@migrate.mysql_columns_query(name), []),
    )
    let indexes = all_indexes
      .filter(ix => ix.table == name)
      .map(ix => @schema.index(ix.columns, name=ix.name, unique=ix.unique))
    tables.push({ name, columns, indexes })
  }
  @schema.Schema::new(tables)
}

///|
async fn run_mysql_steps(
  conn : @mysql.MysqlConn,
  steps : Array[@migrate.Step],
) -> Unit {
  for step in steps {
    conn.begin()
    for statement in step.statements {
      conn.execute(statement.sql, statement.params) |> ignore
    }
    conn.commit()
  }
}

///|
async test "revision migrations round-trip on a real MySQL server" {
  guard live() else { return }
  let conn = @mysql.MysqlConn::connect(
    env_or("MYSQLHOST", "127.0.0.1"),
    env_port("MYSQLPORT", 3306),
    env_or("MYSQLUSER", "root"),
    env_or("MYSQLPASSWORD", "pw"),
    env_or("MYSQLDATABASE", "orm"),
  )
  let migrator = @migrate.Migrator::new()
  let revisions = portable_revisions()
  defer conn.close()
  conn.execute(
    "DROP TABLE IF EXISTS heroes, teams, moonorm_revisions",
    [],
  )
  |> ignore
  conn.execute(@migrate.revisions_table_sql("moonorm_revisions"), []) |> ignore
  let up = migrator.upgrade_sql(revisions, [], target="heads", dialect=@query.Mysql)
  assert_eq(up.length(), 4)
  run_mysql_steps(conn, up)
  let after_upgrade = mysql_schema(conn).snapshot(@query.Mysql)
  assert_eq(after_upgrade.contains("table heroes"), true)
  assert_eq(after_upgrade.contains("column strength INT"), true)
  assert_eq(after_upgrade.contains("index ix_teams_name (name)"), true)
  let applied = @migrate.table_names_of(
    conn.query("SELECT id FROM moonorm_revisions ORDER BY id", []),
  )
  assert_eq(applied, ["0001", "0002", "0003", "0004"])
  let down = migrator.downgrade_sql(
    revisions,
    applied,
    target="base",
    dialect=@query.Mysql,
  )
  assert_eq(down.length(), 4)
  run_mysql_steps(conn, down)
  let at_base = mysql_schema(conn).snapshot(@query.Mysql)
  assert_eq(at_base.contains("table heroes"), false)
  run_mysql_steps(conn, up)
  let after_second = mysql_schema(conn).snapshot(@query.Mysql)
  assert_eq(after_second, after_upgrade)
}
