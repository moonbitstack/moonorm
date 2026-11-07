// The quick-start transcript over the synchronous session and a real SQLite file —
// the reference the two server engines are compared against, and the only run of the
// three that needs no server.

///|
/// Run the quick start through `Session` and return the transcript.
fn quickstart_sync(
  driver : &@moondb.Driver,
) -> Array[String] raise @moondb.DbError {
  let sess = @session.Session::new(driver)
  let users = user_model()
  let addresses = address_model()
  let out : Array[String] = []
  for statement in quickstart_ddl(@query.Sqlite) {
    sess.execute(statement, []) |> ignore
  }
  // `session.add_all([...])` then one commit, as the quick start does.
  sess.begin()
  sess.add_all(users, quickstart_users())
  sess.add_all(addresses, quickstart_addresses())
  sess.commit()

  // `select(User).where(User.name == "sandy")`
  let sandy = sess.fetch_as(
    users,
    users.select().where_("name", "=", @moondb.Text("sandy")),
  )
  out.push("select-sandy: " + sandy[0].fullname.unwrap_or(""))

  // `select(User).order_by(User.id)` — the whole result, in order.
  let ordered = sess.fetch_as(users, users.select().order_by("id", Asc))
  out.push("ordered-by-id: " + ordered.map(u => u.name).join(", "))

  // A join with GROUP BY: one count per user, in name order.
  let (sql, params) = addresses_per_user_query()
  let counts = sess.query(sql, params)
  let line : Array[String] = []
  for row in counts {
    line.push(row.text(0) + "=" + value_text(row.get(1)))
  }
  out.push("addresses-per-user: " + line.join(", "))

  // `user.addresses` — the explicit load, since there is no attribute to intercept.
  let rel = @schema.has_many(address_model(), "user_id", (u : User) => {
    @moondb.Int(u.id)
  })
  let loaded = sess.load(
    { id: 2, name: "sandy", fullname: Some("Sandy Cheeks"), },
    rel,
  )
  out.push("addresses-of-sandy: " + loaded.map(a => a.email_address).join(", "))

  // `sandy.fullname = "Sandy Squirrel"; session.commit()`
  sess.begin()
  sess.update_record(users, {
    id: 2,
    name: "sandy",
    fullname: Some("Sandy Squirrel"),
  })
  sess.commit()
  let updated = sess.fetch_as(
    users,
    users.select().where_("id", "=", @moondb.Int(2)),
  )
  out.push("after-update: " + updated[0].fullname.unwrap_or(""))

  // `session.delete(patrick); session.commit()`
  sess.begin()
  sess.delete_record(users, { id: 3, name: "patrick", fullname: None, })
  sess.commit()
  let left = sess
    .scalar(count_query("user_account"))
    .unwrap_or(@moondb.Int64(0L))
  let left_addresses = sess
    .scalar(count_query("address"))
    .unwrap_or(@moondb.Int64(0L))
  out.push(
    "after-delete: " +
    value_text(left) +
    " users, " +
    value_text(left_addresses) +
    " addresses",
  )
  // Leave the database as it was found: the module's other tests reflect the whole
  // schema, and a stray table here would read as drift in theirs.
  for
    statement in [
      "DROP TABLE IF EXISTS address", "DROP TABLE IF EXISTS user_account",
    ] {
    sess.execute(statement, []) |> ignore
  }
  sess.close()
  out
}

///|
test "orm quick start: SQLite reproduces the transcript" {
  let path = @env.get_env_var("TEMP").unwrap_or(".") + "/moonorm-quickstart.db"
  let driver = @sqlite.SqliteDriver::open(path) catch {
    error => abort("open failed: " + error.to_string())
  }
  let out = quickstart_sync(driver) catch {
    error => abort("quick start failed: " + error.to_string())
  }
  assert_eq(out, expected_quickstart())
}
