///|
test "sqlite: memory, relative file and absolute file" {
  let mem = parse_dsn("sqlite://")
  assert_eq(mem.dialect == @query.Sqlite, true)
  assert_eq(mem.driver, "sqlite")
  assert_eq(mem.database == None, true)
  let rel = parse_dsn("sqlite:///heroes.db")
  assert_eq(rel.database == Some("heroes.db"), true)
  let abs = parse_dsn("sqlite:////var/heroes.db")
  assert_eq(abs.database == Some("/var/heroes.db"), true)
  let short = parse_dsn("sqlite::memory:")
  assert_eq(short.database == None, true)
}

///|
test "postgres: credentials, host, port, database and query params" {
  let pg = parse_dsn(
    "postgresql://leo:secret@db.example:5433/heroes?sslmode=require&timeout=5",
  )
  assert_eq(pg.dialect == @query.Postgres, true)
  assert_eq(pg.driver, "postgresql")
  assert_eq(pg.user == Some("leo"), true)
  assert_eq(pg.password == Some("secret"), true)
  assert_eq(pg.host == Some("db.example"), true)
  assert_eq(pg.port == Some(5433), true)
  assert_eq(pg.database == Some("heroes"), true)
  assert_eq(pg.params.get("sslmode") == Some("require"), true)
  assert_eq(pg.params.get("timeout") == Some("5"), true)
}

///|
test "postgres alias, no port, and a +driver suffix" {
  let short = parse_dsn("postgres://localhost/db")
  assert_eq(short.dialect == @query.Postgres, true)
  assert_eq(short.port == None, true)
  let asyncpg = parse_dsn("postgresql+asyncpg://localhost/db")
  assert_eq(asyncpg.dialect == @query.Postgres, true)
  assert_eq(asyncpg.driver, "asyncpg")
}

///|
test "mysql: dialect, driver, password presence" {
  let my = parse_dsn("mysql://root@127.0.0.1:3306/heroes")
  assert_eq(my.dialect == @query.Mysql, true)
  assert_eq(my.user == Some("root"), true)
  assert_eq(my.password == None, true)
  assert_eq(my.host == Some("127.0.0.1"), true)
  assert_eq(my.port == Some(3306), true)
  let pymysql = parse_dsn("mysql+pymysql://root:pw@localhost/heroes")
  assert_eq(pymysql.driver, "pymysql")
  assert_eq(pymysql.dialect == @query.Mysql, true)
  assert_eq(pymysql.password == Some("pw"), true)
}

///|
test "an unknown scheme is refused" {
  let mut refused = false
  try parse_dsn("oracle://host/db") |> ignore catch {
    _ => refused = true
  }
  assert_eq(refused, true)
}

///|
test "a string with no scheme is refused" {
  let mut refused = false
  try parse_dsn("just-a-file.db") |> ignore catch {
    _ => refused = true
  }
  assert_eq(refused, true)
}

///|
test "engine selects the dialect and binds it to a session" {
  try {
    let engine = Engine::new("mysql://root@localhost/heroes")
    assert_eq(engine.dialect() == @query.Mysql, true)
    assert_eq(engine.driver(), "mysql")
    let driver = @moondb.MockDriver::new()
    let session = engine.session(driver)
    assert_eq(session.dialect() == @query.Mysql, true)
  } catch {
    _ => abort("Engine::new raised on a valid URL")
  }
}

///|
test "engine from an already parsed dsn" {
  let dsn = parse_dsn("sqlite:///heroes.db")
  let engine = Engine::from_dsn(dsn)
  assert_eq(engine.dialect() == @query.Sqlite, true)
}
