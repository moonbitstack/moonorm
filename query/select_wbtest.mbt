///|
test "select: columns, where, order, limit — parameterized" {
  let (sql, params) = select("users")
    .column("id")
    .column("name")
    .eq("age", Int(18))
    .where_("name", "LIKE", Text("bob%"))
    .order_by("name", Asc)
    .limit(10)
    .build()
  assert_eq(
    sql, "SELECT id, name FROM users WHERE age = ? AND name LIKE ? ORDER BY name ASC LIMIT 10",
  )
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Int(18), true)
  assert_eq(params[1] == Text("bob%"), true)
}

///|
test "select: star projection and offset" {
  let (sql, _) = select("t").limit(5).offset(10).build()
  assert_eq(sql, "SELECT * FROM t LIMIT 5 OFFSET 10")
}

///|
test "injection-safe: a value is never spliced into the SQL string" {
  let evil = "'; DROP TABLE users; --"
  let (sql, params) = select("users").eq("name", Text(evil)).build()
  assert_eq(sql, "SELECT * FROM users WHERE name = ?")
  assert_eq(params[0] == Text(evil), true)
}

///|
test "select: join + group_by + having, clause order and params" {
  let (sql, params) = select("orders")
    .raw("users.name")
    .count()
    .join("users", "users.id = orders.user_id")
    .left_join("regions", "regions.id = users.region_id")
    .eq("orders.status", Text("paid"))
    .group_by("users.name")
    .having("COUNT(*)", ">", Int(3))
    .order_by("users.name", Asc)
    .limit(20)
    .build()
  assert_eq(
    sql, "SELECT users.name, COUNT(*) FROM orders JOIN users ON users.id = orders.user_id LEFT JOIN regions ON regions.id = users.region_id WHERE orders.status = ? GROUP BY users.name HAVING COUNT(*) > ? ORDER BY users.name ASC LIMIT 20",
  )
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Text("paid"), true)
  assert_eq(params[1] == Int(3), true)
}

///|
test "select: multiple group_by columns and count aggregate" {
  let (sql, _) = select("sales")
    .column("region")
    .column("year")
    .count()
    .group_by("region")
    .group_by("year")
    .build()
  assert_eq(
    sql, "SELECT region, year, COUNT(*) FROM sales GROUP BY region, year",
  )
}

///|
test "having stays parameterized (injection-safe)" {
  let evil = "0 OR 1=1"
  let (sql, params) = select("t")
    .count()
    .group_by("g")
    .having("SUM(x)", ">", Text(evil))
    .build()
  assert_eq(sql, "SELECT COUNT(*) FROM t GROUP BY g HAVING SUM(x) > ?")
  assert_eq(params[0] == Text(evil), true)
}

///|
test "window: ROW_NUMBER with PARTITION BY and ORDER BY, aliased" {
  let (sql, params) = select("emp")
    .column("name")
    .window(
      "ROW_NUMBER()",
      partition_by=["dept"],
      order_by=[("salary", Desc)],
      as_="rn",
    )
    .build()
  assert_eq(
    sql, "SELECT name, ROW_NUMBER() OVER (PARTITION BY dept ORDER BY salary DESC) AS rn FROM emp",
  )
  assert_eq(params.length(), 0)
}

///|
test "window: multi-column partition and order, running aggregate, no alias" {
  let (sql, _) = select("sales")
    .window("SUM(amount)", partition_by=["region", "year"], order_by=[
      ("month", Asc),
    ])
    .build()
  assert_eq(
    sql, "SELECT SUM(amount) OVER (PARTITION BY region, year ORDER BY month ASC) FROM sales",
  )
}

///|
test "window: empty partition and order yields OVER ()" {
  let (sql, _) = select("t").window("COUNT(*)", as_="total").build()
  assert_eq(sql, "SELECT COUNT(*) OVER () AS total FROM t")
}

///|
test "window: coexists with a real WHERE that still binds its value" {
  let (sql, params) = select("emp")
    .window("RANK()", partition_by=["dept"], order_by=[("salary", Desc)])
    .eq("active", Bool(true))
    .build()
  assert_eq(
    sql, "SELECT RANK() OVER (PARTITION BY dept ORDER BY salary DESC) FROM emp WHERE active = ?",
  )
  assert_eq(params.length(), 1)
  assert_eq(params[0] == Bool(true), true)
}

///|
test "SELECT DISTINCT dedups the projection" {
  let (sql, _) = select("orders").distinct().column("city").build()
  assert_eq(sql, "SELECT DISTINCT city FROM orders")
}

///|
test "set operations render per the SQL standard" {
  assert_eq(
    select("a").column("x").union(select("b").column("x")).build().0,
    "SELECT x FROM a UNION SELECT x FROM b",
  )
  assert_eq(
    select("a").column("x").union_all(select("b").column("x")).build().0,
    "SELECT x FROM a UNION ALL SELECT x FROM b",
  )
  assert_eq(
    select("a").column("x").intersect(select("b").column("x")).build().0,
    "SELECT x FROM a INTERSECT SELECT x FROM b",
  )
  assert_eq(
    select("a").column("x").except_(select("b").column("x")).build().0,
    "SELECT x FROM a EXCEPT SELECT x FROM b",
  )
}

///|
test "a trailing ORDER BY / LIMIT binds to the whole compound" {
  let (sql, _) = select("a")
    .column("x")
    .union(select("b").column("x"))
    .order_by("x", Asc)
    .limit(10)
    .build()
  assert_eq(
    sql, "SELECT x FROM a UNION SELECT x FROM b ORDER BY x ASC LIMIT 10",
  )
}

///|
test "parameters thread through both set-operation operands in order" {
  let (sql, params) = select("a")
    .column("x")
    .where_("x", ">", Int(1))
    .union(select("b").column("x").where_("x", "<", Int(9)))
    .build()
  assert_eq(
    sql, "SELECT x FROM a WHERE x > ? UNION SELECT x FROM b WHERE x < ?",
  )
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Int(1), true)
  assert_eq(params[1] == Int(9), true)
}

///|
test "review fixes: offset-only limit, IS NULL fold, bulk insert, EXISTS" {
  // B2: a bare OFFSET synthesises an effectively-unbounded LIMIT (SQLite/MySQL
  // reject `OFFSET` without `LIMIT`).
  let (o, _) = select("t").offset(10).build()
  assert_eq(o, "SELECT * FROM t LIMIT 9223372036854775807 OFFSET 10")
  // B6: `= NULL` / `!= NULL` fold to IS NULL / IS NOT NULL and bind nothing.
  let (n1, p1) = select("t").eq("a", Null).build()
  assert_eq(n1, "SELECT * FROM t WHERE a IS NULL")
  assert_eq(p1.length(), 0)
  let (n2, _) = select("t").where_("a", "!=", Null).build()
  assert_eq(n2, "SELECT * FROM t WHERE a IS NOT NULL")
  // Bulk insert: one VALUES tuple per row, every value bound in order.
  let (bi, bp) = insert("t")
    .set("a", Int(1))
    .set("b", Int(2))
    .values([Int(3), Int(4)])
    .values([Int(5), Int(6)])
    .build()
  assert_eq(bi, "INSERT INTO t (a, b) VALUES (?, ?), (?, ?), (?, ?)")
  assert_eq(bp.length(), 6)
  assert_eq(bp[4] == Int(5), true)
  // EXISTS subquery, its bound value spliced in at position.
  let sub = select("o").column("1").where_("o.uid", "=", Int(7))
  let (e, ep) = select("u").where_exists(sub).build()
  assert_eq(e, "SELECT * FROM u WHERE EXISTS (SELECT 1 FROM o WHERE o.uid = ?)")
  assert_eq(ep[0] == Int(7), true)
}

///|
test "a tighter-binding operator does not silently regroup what is left of it" {
  let (sql, _) = select("a")
    .column("x")
    .union(select("b").column("x"))
    .intersect(select("c").column("x"))
    .build()
  assert_eq(
    sql, "SELECT * FROM (SELECT x FROM a UNION SELECT x FROM b) AS _c INTERSECT SELECT x FROM c",
  )
}

///|
test "one repeated operator needs no grouping" {
  let (sql, _) = select("a")
    .column("x")
    .union(select("b").column("x"))
    .union(select("c").column("x"))
    .build()
  assert_eq(sql, "SELECT x FROM a UNION SELECT x FROM b UNION SELECT x FROM c")
  let (e, _) = select("a")
    .column("x")
    .except_(select("b").column("x"))
    .union(select("c").column("x"))
    .build()
  assert_eq(e, "SELECT x FROM a EXCEPT SELECT x FROM b UNION SELECT x FROM c")
}

///|
test "a looser operator after a tighter one already groups correctly" {
  let (sql, _) = select("a")
    .column("x")
    .intersect(select("b").column("x"))
    .union(select("c").column("x"))
    .build()
  assert_eq(
    sql, "SELECT x FROM a INTERSECT SELECT x FROM b UNION SELECT x FROM c",
  )
}

///|
test "a compound operand becomes a derived table so it keeps its own shape" {
  let (sql, _) = select("a")
    .column("x")
    .union(select("b").column("x").intersect(select("c").column("x")))
    .build()
  assert_eq(
    sql, "SELECT x FROM a UNION SELECT * FROM (SELECT x FROM b INTERSECT SELECT x FROM c) AS _c",
  )
}

///|
test "an operand's own ORDER BY / LIMIT stays its own" {
  let (sql, params) = select("a")
    .column("x")
    .where_("x", ">", Int(1))
    .union(select("b").column("x").where_("x", "<", Int(9)).limit(2))
    .build()
  assert_eq(
    sql, "SELECT x FROM a WHERE x > ? UNION SELECT * FROM (SELECT x FROM b WHERE x < ? LIMIT 2) AS _c",
  )
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Int(1), true)
  assert_eq(params[1] == Int(9), true)
  let (o, _) = select("a")
    .column("x")
    .union(select("b").column("x").order_by("x", Desc))
    .build()
  assert_eq(
    o, "SELECT x FROM a UNION SELECT * FROM (SELECT x FROM b ORDER BY x DESC) AS _c",
  )
  let (off, _) = select("a")
    .column("x")
    .union(select("b").column("x").offset(5))
    .build()
  assert_eq(
    off, "SELECT x FROM a UNION SELECT * FROM (SELECT x FROM b LIMIT 9223372036854775807 OFFSET 5) AS _c",
  )
  let (lock, _) = select("a")
    .column("x")
    .union(select("b").column("x").for_update())
    .build()
  assert_eq(
    lock, "SELECT x FROM a UNION SELECT * FROM (SELECT x FROM b FOR UPDATE) AS _c",
  )
}

///|
test "an operand carrying its own WITH is grouped too" {
  let (sql, _) = select("a")
    .column("x")
    .union(select("cte").column("x").with_cte("cte", select("b").column("x")))
    .build()
  assert_eq(
    sql, "SELECT x FROM a UNION SELECT * FROM (WITH cte AS (SELECT x FROM b) SELECT x FROM cte) AS _c",
  )
}

///|
test "having: = NULL folds the same way" {
  let (sql, params) = select("t")
    .group_by("g")
    .having("MAX(x)", "=", Null)
    .having("COUNT(*)", ">", Int(3))
    .build()
  assert_eq(
    sql, "SELECT * FROM t GROUP BY g HAVING MAX(x) IS NULL AND COUNT(*) > ?",
  )
  assert_eq(params.length(), 1)
  assert_eq(params[0] == Int(3), true)
}

///|
test "for_update: FOR UPDATE/FOR SHARE with OF, NOWAIT and SKIP LOCKED, after LIMIT" {
  // FOR UPDATE is emitted after LIMIT/OFFSET.
  let (sql1, _) = select("t").limit(5).for_update().build()
  assert_eq(sql1.contains("LIMIT 5 FOR UPDATE"), true)
  // read=true selects FOR SHARE instead.
  let (sql2, _) = select("t").for_update(read=true).build()
  assert_eq(sql2.contains("FOR SHARE"), true)
  assert_eq(sql2.contains("FOR UPDATE"), false)
  // OF restricts the lock; NOWAIT fails fast on a locked row.
  let (sql3, _) = select("t").for_update(of=["t"], nowait=true).build()
  assert_eq(sql3.contains("FOR UPDATE OF t NOWAIT"), true)
  // SKIP LOCKED skips locked rows.
  let (sql4, _) = select("t").for_update(skip_locked=true).build()
  assert_eq(sql4.contains("FOR UPDATE SKIP LOCKED"), true)
  // No lock requested: no locking clause.
  let (sql5, _) = select("t").build()
  assert_eq(sql5.contains("FOR UPDATE"), false)
  assert_eq(sql5.contains("FOR SHARE"), false)
}

///|
test "a Select is a safe base to branch from" {
  let base = select("t").column("id")
  let a = base.eq("k", Int(1))
  let b = base.eq("k", Int(2))
  assert_eq(base.build().0, "SELECT id FROM t")
  let (asql, ap) = a.build()
  assert_eq(asql, "SELECT id FROM t WHERE k = ?")
  assert_eq(ap.length(), 1)
  assert_eq(ap[0] == Int(1), true)
  let (bsql, bp) = b.build()
  assert_eq(bsql, "SELECT id FROM t WHERE k = ?")
  assert_eq(bp[0] == Int(2), true)
}

///|
test "branching leaves the base untouched, clause by clause" {
  let base = select("t").column("id").order_by("id", Asc)
  let tail = " ORDER BY id ASC"
  assert_eq(base.column("name").build().0, "SELECT id, name FROM t" + tail)
  assert_eq(
    base.join("u", "u.id = t.id").build().0,
    "SELECT id FROM t JOIN u ON u.id = t.id" + tail,
  )
  assert_eq(
    base.with_cte("c", select("z")).build().0,
    "WITH c AS (SELECT * FROM z) SELECT id FROM t" + tail,
  )
  assert_eq(
    base.group_by("k").having("COUNT(*)", ">", Int(1)).build().0,
    "SELECT id FROM t GROUP BY k HAVING COUNT(*) > ?" + tail,
  )
  assert_eq(
    base.order_by("k", Desc).build().0,
    "SELECT id FROM t ORDER BY id ASC, k DESC",
  )
  assert_eq(
    base.distinct_on(["id"]).build().0,
    "SELECT DISTINCT ON (id) id FROM t" + tail,
  )
  assert_eq(base.limit(5).build().0, "SELECT id FROM t" + tail + " LIMIT 5")
  assert_eq(
    base.for_update().build().0,
    "SELECT id FROM t" + tail + " FOR UPDATE",
  )
  assert_eq(
    base.union(select("u").column("id")).build().0,
    "SELECT id FROM t UNION SELECT id FROM u" + tail,
  )
  assert_eq(
    base.eq("k", Int(1)).build().0,
    "SELECT id FROM t WHERE k = ?" + tail,
  )
  assert_eq(
    base.where_in_values("k", [Int(1)]).build().0,
    "SELECT id FROM t WHERE k IN (?)" + tail,
  )
  assert_eq(
    base.where_in("k", select("z").column("id")).build().0,
    "SELECT id FROM t WHERE k IN (SELECT id FROM z)" + tail,
  )
  assert_eq(
    base.where_pred(Cmp(col="k", op="=", val=Int(1))).build().0,
    "SELECT id FROM t WHERE k = ?" + tail,
  )
  assert_eq(base.build().0, "SELECT id FROM t" + tail)
}

///|
test "with_recursive leaves the anchor a plain query" {
  let anchor = select("n").column("x").where_("x", "=", Int(0))
  let step = select("n").column("x + 1")
  let q = select("n").with_recursive("n", anchor, step)
  assert_eq(anchor.build().0, "SELECT x FROM n WHERE x = ?")
  assert_eq(
    q.build().0,
    "WITH RECURSIVE n AS (SELECT x FROM n WHERE x = ? UNION SELECT x + 1 FROM n) SELECT * FROM n",
  )
}

///|
test "a set operation leaves both operands alone" {
  let a = select("a").column("x")
  let b = select("b").column("x")
  let both = a.union(b)
  assert_eq(a.build().0, "SELECT x FROM a")
  assert_eq(b.build().0, "SELECT x FROM b")
  assert_eq(both.build().0, "SELECT x FROM a UNION SELECT x FROM b")
}

///|
test "FROM a derived table: its values bind before the WHERE's" {
  let sub = select("orders").column("uid").where_("total", ">", Int(100))
  let (sql, params) = select(Alias(Sub(sub), "o"))
    .column("o.uid")
    .where_("o.uid", "<", Int(50))
    .build()
  assert_eq(
    sql, "SELECT o.uid FROM (SELECT uid FROM orders WHERE total > ?) AS o WHERE o.uid < ?",
  )
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Int(100), true)
  assert_eq(params[1] == Int(50), true)
}

///|
test "JOIN a derived table: FROM, JOIN then WHERE values, in text order" {
  let a = select("a").column("id").where_("x", "=", Int(1))
  let b = select("b").column("id").where_("y", "=", Int(2))
  let (sql, params) = select(Alias(Sub(a), "ta"))
    .column("ta.id")
    .join(Alias(Sub(b), "tb"), "tb.id = ta.id")
    .where_("ta.id", ">", Int(3))
    .build()
  assert_eq(
    sql, "SELECT ta.id FROM (SELECT id FROM a WHERE x = ?) AS ta JOIN (SELECT id FROM b WHERE y = ?) AS tb ON tb.id = ta.id WHERE ta.id > ?",
  )
  assert_eq(params.length(), 3)
  assert_eq(params[0] == Int(1), true)
  assert_eq(params[1] == Int(2), true)
  assert_eq(params[2] == Int(3), true)
}

///|
test "aliased tables in FROM and JOIN" {
  let (sql, _) = select(Alias(Tbl("users"), "u"))
    .column("u.id")
    .left_join(Alias(Tbl("teams"), "t"), "t.id = u.team_id")
    .build()
  assert_eq(
    sql, "SELECT u.id FROM users AS u LEFT JOIN teams AS t ON t.id = u.team_id",
  )
}

///|
test "a bare table name still reads as a source" {
  let (sql, _) = select("users")
    .join("teams", "teams.id = users.team_id")
    .build()
  assert_eq(sql, "SELECT * FROM users JOIN teams ON teams.id = users.team_id")
}

///|
test "the other join kinds: right, full, cross, using" {
  assert_eq(
    select("a").right_join("b", "b.k = a.k").build().0,
    "SELECT * FROM a RIGHT JOIN b ON b.k = a.k",
  )
  assert_eq(
    select("a").full_join("b", "b.k = a.k").build().0,
    "SELECT * FROM a FULL JOIN b ON b.k = a.k",
  )
  assert_eq(
    select("a").cross_join("b").build().0,
    "SELECT * FROM a CROSS JOIN b",
  )
  assert_eq(
    select("a").join_using("b", ["k", "j"]).build().0,
    "SELECT * FROM a JOIN b USING (k, j)",
  )
}

///|
test "LATERAL: a per-row derived table, values bound" {
  let sub = select("orders")
    .column("id")
    .where_("orders.uid", "=", Int(5))
    .limit(3)
  let (sql, params) = select("users")
    .cross_join(Alias(Lateral(Sub(sub)), "o"))
    .build()
  assert_eq(
    sql, "SELECT * FROM users CROSS JOIN LATERAL (SELECT id FROM orders WHERE orders.uid = ? LIMIT 3) AS o",
  )
  assert_eq(params.length(), 1)
  assert_eq(params[0] == Int(5), true)
}

///|
test "DISTINCT ON keeps the first row of each group" {
  let (sql, _) = select("t")
    .distinct_on(["a"])
    .column("a")
    .column("b")
    .order_by("a", Asc)
    .order_by("b", Desc)
    .build()
  assert_eq(sql, "SELECT DISTINCT ON (a) a, b FROM t ORDER BY a ASC, b DESC")
}

///|
test "builder: WITH renders a leading CTE and its params come first" {
  let recent = select("orders").column("user_id").where_("total", ">", Int(100))
  let (sql, params) = select("users")
    .column("id")
    .column("name")
    .with_cte("big_spenders", recent)
    .where_("active", "=", Bool(true))
    .build()
  assert_eq(
    sql, "WITH big_spenders AS (SELECT user_id FROM orders WHERE total > ?) SELECT id, name FROM users WHERE active = ?",
  )
  // CTE param (100) leads; the outer WHERE param (true) follows — text order.
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Int(100), true)
  assert_eq(params[1] == Bool(true), true)
}

///|
test "builder: WHERE col IN (subquery) binds the subquery's values in place" {
  let team_ids = select("teams").column("id").where_("region", "=", Text("EU"))
  let (sql, params) = select("heroes")
    .where_("active", "=", Bool(true))
    .where_in("team_id", team_ids)
    .build()
  assert_eq(
    sql, "SELECT * FROM heroes WHERE active = ? AND team_id IN (SELECT id FROM teams WHERE region = ?)",
  )
  // Scalar predicate first (true), then the subquery's bound value (\"EU\").
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Bool(true), true)
  assert_eq(params[1] == Text("EU"), true)
}

///|
test "builder: NOT IN subquery and an injection attempt stays a bound value" {
  let evil = "1); DROP TABLE users; --"
  let banned = select("bans").column("user_id").where_("kind", "=", Text(evil))
  let (sql, params) = select("users").where_not_in("id", banned).build()
  assert_eq(
    sql, "SELECT * FROM users WHERE id NOT IN (SELECT user_id FROM bans WHERE kind = ?)",
  )
  // The malicious string never reaches the SQL text; it rides as a bound param.
  assert_eq(params.length(), 1)
  assert_eq(params[0] == Text(evil), true)
  assert_eq(sql.contains("DROP TABLE"), false)
}

///|
test "builder: a CTE combined with a subquery predicate keeps params in text order" {
  let cte_sub = select("a").column("x").where_("p", "=", Int(1))
  let in_sub = select("b").column("y").where_("q", "=", Int(3))
  let (sql, params) = select("t")
    .with_cte("c", cte_sub)
    .where_("r", "=", Int(2))
    .where_in("y", in_sub)
    .build()
  assert_eq(
    sql, "WITH c AS (SELECT x FROM a WHERE p = ?) SELECT * FROM t WHERE r = ? AND y IN (SELECT y FROM b WHERE q = ?)",
  )
  // CTE(1) -> scalar WHERE(2) -> subquery WHERE(3): exactly the SQL text order.
  assert_eq(params.length(), 3)
  assert_eq(params[0] == Int(1), true)
  assert_eq(params[1] == Int(2), true)
  assert_eq(params[2] == Int(3), true)
}

///|
test "builder: WITH RECURSIVE UNION ALL walks a counter and leads with its params" {
  let anchor = select("seed").column("n").where_("n", "=", Int(233))
  let step = select("cnt").column("n + 1").where_("n", "<", Int(66666))
  let (sql, params) = select("cnt")
    .with_recursive("cnt", anchor, step, all=true)
    .column("n")
    .build()
  assert_eq(
    sql, "WITH RECURSIVE cnt AS (SELECT n FROM seed WHERE n = ? UNION ALL SELECT n + 1 FROM cnt WHERE n < ?) SELECT n FROM cnt",
  )
  // Anchor bound value (233) first, recursive term (66666) next — both lead the
  // outer query because the WITH clause leads the SQL text.
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Int(233), true)
  assert_eq(params[1] == Int(66666), true)
}

///|
test "builder: WITH RECURSIVE UNION references the CTE name in the recursive term's JOIN" {
  let roots = select("org")
    .column("id")
    .column("parent_id")
    .where_("parent_id", "=", Null)
  let branch = select("org")
    .column("org.id")
    .column("org.parent_id")
    .join("tree", "org.parent_id = tree.id")
  let (sql, _) = select("tree")
    .with_recursive("tree", roots, branch)
    .column("id")
    .column("parent_id")
    .build()
  assert_eq(
    sql, "WITH RECURSIVE tree AS (SELECT id, parent_id FROM org WHERE parent_id IS NULL UNION SELECT org.id, org.parent_id FROM org JOIN tree ON org.parent_id = tree.id) SELECT id, parent_id FROM tree",
  )
}

// --- Optimistic lock -----------------------------------------------------------
