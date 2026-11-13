// The two tables the differential shares with the SQLAlchemy reference in
// `integration/reference`. Same storage classes, same key, same foreign key, same
// index — declared here the way a user of this library declares them, so a difference
// in what the two leave behind is a difference in the library and not in the spelling
// of a type.

///|
/// An account: a natural key (`email`, unique), a score and a timestamp that stays
/// null in the seeded rows because the two frameworks spell a stored timestamp
/// differently and this transcript compares behaviour, not formatting.
pub struct RefAccount {
  id : Int64
  email : String
  name : String
  score : Double
  created : String?
}

///|
/// An article, owned by an account. Deleting the account deletes its articles.
pub struct RefArticle {
  id : Int64
  account_id : Int64
  title : String
  body : String?
  published : Bool
}

///|
pub fn reference_account_model() -> @schema.Model[RefAccount] {
  let fields : Array[@schema.Field[RefAccount]] = [
    @schema.field(
      "id",
      @schema.BigIntType,
      primary_key=true,
      autoincrement=true,
      a => a.id,
    ),
    @schema.field("email", @schema.TextType, nullable=false, unique=true, a => {
      a.email
    }),
    @schema.field("name", @schema.TextType, nullable=false, a => a.name),
    @schema.field("score", @schema.RealType, nullable=false, default="0", a => {
      a.score
    }),
    @schema.field("created", @schema.DateTimeType, a => a.created),
  ]
  @schema.Model::from_fields("account", fields, r => {
    id: r.read(0),
    email: r.text(1),
    name: r.text(2),
    score: r.read(3),
    created: if r.is_null(4) {
      None
    } else {
      Some(r.text(4))
    },
  })
}

///|
pub fn reference_article_model() -> @schema.Model[RefArticle] {
  let fields : Array[@schema.Field[RefArticle]] = [
    @schema.field(
      "id",
      @schema.BigIntType,
      primary_key=true,
      autoincrement=true,
      a => a.id,
    ),
    @schema.field(
      "account_id",
      @schema.BigIntType,
      nullable=false,
      references=("account", "id"),
      on_delete="CASCADE",
      a => a.account_id,
    ),
    @schema.field("title", @schema.TextType, nullable=false, a => a.title),
    @schema.field("body", @schema.TextType, a => a.body),
    @schema.field("published", @schema.BoolType, nullable=false, default="0", a => {
      a.published
    }),
  ]
  @schema.Model::from_fields(
    "article",
    fields,
    r => {
      id: r.read(0),
      account_id: r.read(1),
      title: r.text(2),
      body: if r.is_null(3) {
        None
      } else {
        Some(r.text(3))
      },
      published: r.read(4),
    },
    indexes=[@schema.index(["account_id"], name="ix_article_account_id")],
  )
}

///|
/// The four accounts and four articles the reference seeds: one account with two
/// articles, two with one, one with none, and one article with no body.
pub fn reference_accounts() -> Array[RefAccount] {
  [
    {
      id: 1L,
      email: "alice@example.com",
      name: "alice",
      score: 4.5,
      created: None,
    },
    {
      id: 2L,
      email: "bob@example.com",
      name: "bob",
      score: 2.25,
      created: None,
    },
    {
      id: 3L,
      email: "carol@example.com",
      name: "carol",
      score: 7.25,
      created: None,
    },
    {
      id: 4L,
      email: "dave@example.com",
      name: "dave",
      score: 0.5,
      created: None,
    },
  ]
}

///|
pub fn reference_articles() -> Array[RefArticle] {
  [
    {
      id: 1L,
      account_id: 1L,
      title: "Alpha",
      body: Some("first"),
      published: true,
    },
    { id: 2L, account_id: 1L, title: "Beta", body: None, published: false, },
    {
      id: 3L,
      account_id: 2L,
      title: "Gamma",
      body: Some("third"),
      published: true,
    },
    {
      id: 4L,
      account_id: 3L,
      title: "Delta",
      body: Some("fourth"),
      published: true,
    },
  ]
}

///|
/// Drop what a previous run left, then create the two tables and the index from the
/// models — the same DDL entry points a migration uses.
pub fn reference_ddl() -> Array[String] {
  [
    "DROP TABLE IF EXISTS article",
    "DROP TABLE IF EXISTS account",
    reference_account_model().create_table_sql_for(Sqlite),
    reference_article_model().create_table_sql_for(Sqlite),
    @schema.create_index_sql("ix_article_account_id", "article", ["account_id"]),
  ]
}

///|
/// A fresh database with the schema and the seeded rows, ready for a transcript.
pub fn reference_seed(sess : @session.Session) -> Unit raise @moondb.DbError {
  for statement in reference_ddl() {
    sess.execute(statement, []) |> ignore
  }
  sess.begin()
  for account in reference_accounts() {
    sess.insert_record(reference_account_model(), account) |> ignore
  }
  for article in reference_articles() {
    sess.insert_record(reference_article_model(), article) |> ignore
  }
  sess.commit()
}
