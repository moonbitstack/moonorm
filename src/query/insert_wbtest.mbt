///|
test "insert" {
  let (sql, params) = insert("users")
    .set("name", Text("bob"))
    .set("age", Int(30))
    .build()
  assert_eq(sql, "INSERT INTO users (name, age) VALUES (?, ?)")
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Text("bob"), true)
}

///|
test "insert RETURNING: single and multiple columns (sqlite/pg default)" {
  let (sql, _) = insert("users")
    .set("name", Text("ann"))
    .returning("id")
    .build()
  assert_eq(sql, "INSERT INTO users (name) VALUES (?) RETURNING id")
  let (sql2, _) = insert("users")
    .set("name", Text("ann"))
    .returning("id")
    .returning("created_at")
    .build()
  assert_eq(
    sql2, "INSERT INTO users (name) VALUES (?) RETURNING id, created_at",
  )
  let (sql3, _) = insert("users")
    .set("name", Text("ann"))
    .returning_all()
    .build()
  assert_eq(sql3, "INSERT INTO users (name) VALUES (?) RETURNING *")
}

///|
test "insert RETURNING: MySQL omits the clause" {
  let (sql, _) = insert("users")
    .set("name", Text("ann"))
    .returning("id")
    .build_for(Mysql)
  assert_eq(sql, "INSERT INTO users (name) VALUES (?)")
}

///|
test "upsert DO UPDATE excluded: sqlite/pg form, params in text order" {
  let (sql, params) = insert("kv")
    .set("k", Text("hits"))
    .set("v", Int(1))
    .on_conflict(["k"])
    .do_update_excluded("v")
    .build()
  assert_eq(
    sql, "INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT (k) DO UPDATE SET v = excluded.v",
  )
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Text("hits"), true)
  assert_eq(params[1] == Int(1), true)
}

///|
test "upsert DO UPDATE bound value binds after the inserted values" {
  let (sql, params) = insert("kv")
    .set("k", Text("k1"))
    .set("v", Int(1))
    .on_conflict(["k"])
    .do_update("v", Int(99))
    .build()
  assert_eq(
    sql, "INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT (k) DO UPDATE SET v = ?",
  )
  assert_eq(params.length(), 3)
  assert_eq(params[0] == Text("k1"), true)
  assert_eq(params[1] == Int(1), true)
  assert_eq(params[2] == Int(99), true)
}

///|
test "upsert MySQL form: ON DUPLICATE KEY UPDATE, VALUES() and bound" {
  let (sql, params) = insert("kv")
    .set("k", Text("k1"))
    .set("v", Int(1))
    .on_conflict(["k"])
    .do_update_excluded("v")
    .do_update("seen", Int64(42L))
    .build_for(Mysql)
  assert_eq(
    sql, "INSERT INTO kv (k, v) VALUES (?, ?) ON DUPLICATE KEY UPDATE v = VALUES(v), seen = ?",
  )
  assert_eq(params.length(), 3)
  assert_eq(params[2] == Int64(42L), true)
}

///|
test "upsert DO NOTHING: sqlite/pg vs MySQL no-op self-assignment" {
  let (sql, _) = insert("kv")
    .set("k", Text("k1"))
    .set("v", Int(1))
    .on_conflict(["k"])
    .do_nothing()
    .build()
  assert_eq(
    sql, "INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT (k) DO NOTHING",
  )
  let (my, _) = insert("kv")
    .set("k", Text("k1"))
    .set("v", Int(1))
    .on_conflict(["k"])
    .do_nothing()
    .build_for(Mysql)
  assert_eq(
    my, "INSERT INTO kv (k, v) VALUES (?, ?) ON DUPLICATE KEY UPDATE k = k",
  )
}

///|
test "upsert RETURNING together: conflict clause then RETURNING, correct params" {
  let (sql, params) = insert("counter")
    .set("name", Text("visits"))
    .set("n", Int(1))
    .on_conflict(["name"])
    .do_update("n", Int(100))
    .returning("n")
    .build()
  assert_eq(
    sql, "INSERT INTO counter (name, n) VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET n = ? RETURNING n",
  )
  assert_eq(params.length(), 3)
  assert_eq(params[2] == Int(100), true)
}

///|
test "upsert injection-safe: a hostile value stays bound, never spliced" {
  let evil = "'; DROP TABLE kv; --"
  let (sql, params) = insert("kv")
    .set("k", Text("k1"))
    .set("v", Text(evil))
    .on_conflict(["k"])
    .do_update("v", Text(evil))
    .build()
  assert_eq(
    sql, "INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT (k) DO UPDATE SET v = ?",
  )
  assert_eq(params[1] == Text(evil), true)
  assert_eq(params[2] == Text(evil), true)
}

///|
test "insert: a bulk row without a leading set() emits no empty tuple" {
  let (sql, params) = insert("t").values([Int(233)]).build()
  assert_eq(sql, "INSERT INTO t VALUES (?)")
  assert_eq(params.length(), 1)
  assert_eq(params[0] == Int(233), true)
  let (two, tp) = insert("t")
    .values([Int(1), Int(2)])
    .values([Int(3), Int(4)])
    .build()
  assert_eq(two, "INSERT INTO t VALUES (?, ?), (?, ?)")
  assert_eq(tp.length(), 4)
}

///|
test "insert: nothing to insert is DEFAULT VALUES, or MySQL's () VALUES ()" {
  let (sql, params) = insert("t").build()
  assert_eq(sql, "INSERT INTO t DEFAULT VALUES")
  assert_eq(params.length(), 0)
  let (my, _) = insert("t").build_for(Mysql)
  assert_eq(my, "INSERT INTO t () VALUES ()")
}

///|
test "an Insert is a safe base to branch from" {
  let base = insert("t").set("a", Int(1))
  assert_eq(
    base.set("b", Int(2)).build().0,
    "INSERT INTO t (a, b) VALUES (?, ?)",
  )
  assert_eq(
    base.values([Int(9)]).build().0,
    "INSERT INTO t (a) VALUES (?), (?)",
  )
  assert_eq(
    base.returning("id").build().0,
    "INSERT INTO t (a) VALUES (?) RETURNING id",
  )
  assert_eq(base.build().0, "INSERT INTO t (a) VALUES (?)")
}

///|
test "an Insert's upsert clause branches too" {
  let up = insert("kv").set("k", Text("emm")).on_conflict(["k"])
  let overwrite = up.do_update_excluded("v")
  let wider = up.on_conflict(["j"])
  let nothing = up.do_nothing()
  assert_eq(
    overwrite.build().0,
    "INSERT INTO kv (k) VALUES (?) ON CONFLICT (k) DO UPDATE SET v = excluded.v",
  )
  assert_eq(
    wider.build().0,
    "INSERT INTO kv (k) VALUES (?) ON CONFLICT (k, j) DO UPDATE SET ",
  )
  assert_eq(
    nothing.build().0,
    "INSERT INTO kv (k) VALUES (?) ON CONFLICT (k) DO NOTHING",
  )
}
