///|
/// The parent table heroes point at. An autoincrement key is `T?`: `None` until
/// the database assigns it, and left out of the INSERT meanwhile.
#orm.table(name="teams")
pub struct Team {
  #orm.column(primary_key=true, autoincrement=true)
  id : Int64?
  #orm.column(kind="varchar(64)", unique=true)
  name : String
}

///|
/// A field without annotations is a column named after it, `NOT NULL` unless its
/// type is `T?`. `#orm.skip` keeps a field out of the table and fills it from
/// `Default` when a row is read.
#orm.table(name="heroes")
pub struct Hero {
  #orm.column(primary_key=true, autoincrement=true)
  id : Int64?
  name : String
  #orm.column(name="secret_name", unique=true)
  secret : String
  #orm.column(check="age >= 0", check="age < 1000")
  age : Int32?
  #orm.column(default="0")
  power : Double
  #orm.column(references="teams.id", on_delete="SET NULL")
  team_id : Int64?
  #orm.column(kind="text")
  email : Email
  #orm.skip
  visits : Int32
}

///|
/// A type of the program's own: stored as text, refused on the way back when it
/// has no `@`.
pub struct Email(String) derive(Eq, Debug)

///|
impl @moonorm.ToValue for Email with fn to_value(self) {
  let Email(s) = self
  Text(s)
}

///|
impl @moonorm.FromValue for Email with fn from_value(v) {
  match v {
    Text(s) if s.contains("@") => Email(s)
    other => raise TypeError(other.kind() + ", not Email")
  }
}
