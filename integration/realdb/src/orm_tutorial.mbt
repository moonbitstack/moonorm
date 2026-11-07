// The SQLAlchemy 2 ORM quick start, transcribed: two mapped classes with a
// one-to-many relationship, a batch insert, a filtered read, an ordered read, a join
// with GROUP BY, an eager load, an update and a delete — each producing one line of a
// transcript. The same script runs over a synchronous session on SQLite and over an
// asynchronous session on PostgreSQL and MySQL, and every run has to land on
// `expected_quickstart()`, which is what "the examples give the same result on the
// three engines" means here.
//
// The names and the shape come from SQLAlchemy's own quick start (`User` /
// `Address`, spongebob / sandy / patrick), so a reader can compare the two side by
// side. What cannot be transcribed is attribute interception: `user.addresses` in
// SQLAlchemy fires a SELECT on access, while here the load is a call. The SQL each
// step runs is the same.

///|
/// A user account: `User` in the quick start, minus the address list, which MoonBit
/// cannot hang off a struct and reach by attribute.
priv struct User {
  id : Int32
  name : String
  fullname : String?
}

///|
/// One e-mail address belonging to a user.
priv struct Address {
  id : Int32
  email_address : String
  user_id : Int32
}

///|
fn user_model() -> @schema.Model[User] {
  let fields : Array[@schema.Field[User]] = [
    @schema.field("id", @schema.IntType, u => u.id, primary_key=true),
    @schema.field("name", @schema.TextType, u => u.name, nullable=false),
    @schema.field("fullname", @schema.TextType, u => u.fullname),
  ]
  @schema.Model::from_fields("user_account", fields, r => {
    id: r.int(0),
    name: r.text(1),
    fullname: if r.is_null(2) {
      None
    } else {
      Some(r.text(2))
    },
  })
}

///|
fn address_model() -> @schema.Model[Address] {
  let fields : Array[@schema.Field[Address]] = [
    @schema.field("id", @schema.IntType, a => a.id, primary_key=true),
    @schema.field(
      "email_address",
      @schema.TextType,
      a => a.email_address,
      nullable=false,
    ),
    @schema.field(
      "user_id",
      @schema.IntType,
      a => a.user_id,
      nullable=false,
      references=("user_account", "id"),
    ),
  ]
  @schema.Model::from_fields("address", fields, r => {
    id: r.int(0),
    email_address: r.text(1),
    user_id: r.int(2),
  })
}

///|
/// The transcript every engine has to reproduce. A line names the step and the value
/// SQLAlchemy's own quick start prints for it.
fn expected_quickstart() -> Array[String] {
  [
    "select-sandy: Sandy Cheeks", "ordered-by-id: spongebob, sandy, patrick", "addresses-per-user: sandy=2, spongebob=1",
    "addresses-of-sandy: sandy@sqlalchemy.org, sandy@squirrelpower.org", "after-update: Sandy Squirrel",
    "after-delete: 2 users, 3 addresses",
  ]
}

///|
/// A bound value as the transcript writes it, so a driver that hands back `Int64`
/// where another hands back `Int` still produces the same line.
fn value_text(v : @moondb.Value) -> String {
  match v {
    @moondb.Text(s) => s
    @moondb.Int(n) => n.to_string()
    @moondb.Int64(n) => n.to_string()
    @moondb.Null => "NULL"
    other => other.to_string()
  }
}

///|
/// The seeded rows: three users and three addresses, exactly the quick start's.
fn quickstart_users() -> Array[User] {
  [
    { id: 1, name: "spongebob", fullname: Some("Spongebob Squarepants"), },
    { id: 2, name: "sandy", fullname: Some("Sandy Cheeks"), },
    { id: 3, name: "patrick", fullname: None, },
  ]
}

///|
fn quickstart_addresses() -> Array[Address] {
  [
    { id: 1, email_address: "spongebob@sqlalchemy.org", user_id: 1, },
    { id: 2, email_address: "sandy@sqlalchemy.org", user_id: 2, },
    { id: 3, email_address: "sandy@squirrelpower.org", user_id: 2, },
  ]
}

///|
/// `SELECT COUNT(*)` over one table. A model's own `select()` projects every column,
/// so appending `COUNT(*)` to it would group over those columns — invalid on
/// PostgreSQL, and rejected by MySQL's `ONLY_FULL_GROUP_BY` — and the count query has
/// to be built on its own.
fn count_query(table : String) -> @query.Select {
  @query.select(table).count()
}

///|
/// The `User.name, COUNT(Address.id)` join the quick start uses to show a relationship
/// query. An inner join, as SQLAlchemy's `.join(Address)` is, so a user with no address
/// does not appear — patrick is missing from the transcript for the same reason he is
/// missing from SQLAlchemy's. Both engines accept this text and the parameters travel
/// bound.
fn addresses_per_user_query() -> (String, Array[@moondb.Value]) {
  @query.select("user_account")
  .raw("user_account.name")
  .raw("COUNT(address.id)")
  .join("address", "address.user_id = user_account.id")
  .group_by("user_account.name")
  .order_by("user_account.name", Asc)
  .build()
}

///|
/// The schema every run starts from: the two tables, dropped and recreated so a rerun
/// is independent of what the last one left. `address` goes first — it holds the
/// foreign key.
fn quickstart_ddl(dialect : @query.Dialect) -> Array[String] {
  let user = user_model().create_table_sql_for(dialect, if_not_exists=true)
  let address = address_model().create_table_sql_for(
    dialect,
    if_not_exists=true,
  )
  [
    "DROP TABLE IF EXISTS address", "DROP TABLE IF EXISTS user_account", user, address,
  ]
}

///|
/// A one-column note, for the checks that only need a row to exist.
priv struct Note {
  id : Int32
  body : String
}

///|
fn note_model() -> @schema.Model[Note] {
  let fields : Array[@schema.Field[Note]] = [
    @schema.field("id", @schema.IntType, n => n.id, primary_key=true),
    @schema.field("body", @schema.VarcharType(64), n => n.body, nullable=false),
  ]
  @schema.Model::from_fields("notes", fields, r => {
    id: r.int(0),
    body: r.text(1),
  })
}
