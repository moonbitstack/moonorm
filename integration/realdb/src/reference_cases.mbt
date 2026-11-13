// The ten queries, run through the builder and the session, rendered as the same
// `case|field|field` lines the SQLAlchemy reference writes. Reads first, then the two
// writes, because the writes change what a read would see.

///|
/// One bound value as a transcript field. Nulls spell `null`, so a missing body and
/// the text "null" stay distinguishable.
pub fn reference_value_text(v : @moondb.Value) -> String {
  match v {
    @moondb.Null => "null"
    @moondb.Text(s) => s
    @moondb.Bool(b) => if b { "1" } else { "0" }
    @moondb.Double(d) => d.to_string()
    @moondb.Int(n) => n.to_string()
    @moondb.Int64(n) => n.to_string()
    other => other.to_string()
  }
}

///|
/// Append one line per row of `rows`, each prefixed with the case name.
pub fn reference_collect(
  out : Array[String],
  name : String,
  rows : Array[@moondb.Row],
) -> Unit raise @moondb.DbError {
  for row in rows {
    let fields : Array[String] = []
    for i = 0; i < row.width(); i = i + 1 {
      fields.push(reference_value_text(row.get(i)))
    }
    out.push(name + "|" + fields.join("|"))
  }
}

///|
/// The `account.name, COUNT(article.id)` join: an inner join, grouped, keeping only
/// accounts that have an article — the same shape the reference writes.
pub fn reference_article_counts() -> (String, Array[@moondb.Value]) {
  @query.select("account")
  .raw("account.name")
  .raw("COUNT(article.id)")
  .join("article", "article.account_id = account.id")
  .group_by("account.name")
  .having("COUNT(article.id)", ">", @moondb.Int(0))
  .order_by("account.name", Asc)
  .build()
}

///|
/// Every article with its body, or `(none)` where the body is null.
pub fn reference_bodies() -> (String, Array[@moondb.Value]) {
  @query.select("article")
  .raw("article.title")
  .raw(@query.func("coalesce", ["article.body", "'(none)'"]))
  .order_by("article.title", Asc)
  .build()
}

///|
/// The transcript: one line per row, in case order. `reads_only` leaves out the
/// upsert and the cascading delete, which is what a run against a database that has
/// to stay as declared uses.
pub fn reference_transcript(
  sess : @session.Session,
  reads_only~ : Bool = false,
) -> Array[String] raise @moondb.DbError {
  let out : Array[String] = []
  // 1. Every account, by name.
  let (sql, params) = @query.select("account")
    .column("name")
    .order_by("name", Asc)
    .build()
  reference_collect(out, "names-ordered", sess.query(sql, params))
  // 2. How many articles each account that has one owns.
  let (sql, params) = reference_article_counts()
  reference_collect(out, "article-counts", sess.query(sql, params))
  // 3. Accounts with no article: the left join plus the null test.
  let (sql, params) = @query.select("account")
    .column("account.name")
    .left_join("article", "article.account_id = account.id")
    .where_("article.id", "IS", @moondb.Null)
    .order_by("account.name", Asc)
    .build()
  reference_collect(out, "silent-accounts", sess.query(sql, params))
  // 4. Who published, once per account.
  let (sql, params) = @query.select("account")
    .column("account.name")
    .join("article", "article.account_id = account.id")
    .where_("article.published", "=", @moondb.Bool(true))
    .distinct()
    .order_by("account.name", Asc)
    .build()
  reference_collect(out, "published-authors", sess.query(sql, params))
  // 5. Bodies, with the null rendered as text by `coalesce`.
  let (sql, params) = reference_bodies()
  reference_collect(out, "bodies", sess.query(sql, params))
  // 6. The highest score.
  let (sql, params) = @query.select("account").raw("MAX(account.score)").build()
  reference_collect(out, "max-score", sess.query(sql, params))
  // 7. Articles numbered within their account.
  let (sql, params) = @query.select("account")
    .raw("account.name")
    .window("ROW_NUMBER()", partition_by=["article.account_id"], order_by=[
      ("article.id", Asc),
    ])
    .raw("article.title")
    .join("article", "article.account_id = account.id")
    .order_by("article.id", Asc)
    .build()
  reference_collect(out, "ranked-titles", sess.query(sql, params))
  // 8. The `LIKE` filter.
  let (sql, params) = @query.select("account")
    .column("name")
    .where_("name", "LIKE", @moondb.Text("a%"))
    .order_by("name", Asc)
    .build()
  reference_collect(out, "name-prefix", sess.query(sql, params))
  if reads_only {
    return out
  }
  // 9. An upsert of row 2 that rewrites the title it already holds.
  let (sql, params) = @query.insert("article")
    .set("id", @moondb.Int64(2L))
    .set("account_id", @moondb.Int64(1L))
    .set("title", @moondb.Text("Beta II"))
    .set("body", @moondb.Null)
    .set("published", @moondb.Bool(false))
    .on_conflict(["id"])
    .do_update_excluded("title")
    .build()
  sess.execute(sql, params) |> ignore
  let (sql, params) = @query.select("article")
    .column("title")
    .where_("id", "=", @moondb.Int64(2L))
    .build()
  reference_collect(out, "upsert-beta", sess.query(sql, params))
  // 10. Deleting the account takes its article with it. SQLite enforces a foreign key
  // only when the connection asks it to, so this is the one place the transcript has
  // to turn that on; the reference turns it on the same way.
  sess.execute("PRAGMA foreign_keys = ON", []) |> ignore
  let (sql, params) = @query.delete("account")
    .where_("name", "=", @moondb.Text("carol"))
    .build()
  sess.execute(sql, params) |> ignore
  let accounts = sess.scalar(@query.select("account").count())
  let articles = sess.scalar(@query.select("article").count())
  out.push(
    "cascade-delete|" +
    reference_value_text(accounts.unwrap_or(@moondb.Null)) +
    "|" +
    reference_value_text(articles.unwrap_or(@moondb.Null)),
  )
  out
}
