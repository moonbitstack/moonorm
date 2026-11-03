// --8<-- [start:model]

///|
/// The same account table with both mapping directions written out.
pub struct Account {
  id : Int64?
  email : String
  balance : Double
  team_id : Int64?
  status : String
  level : Int32
}

///|
fn account() -> @moonorm.Model[Account] {
  @moonorm.Model::new(
    "accounts",
    [
      @moonorm.column("id", BigIntType, primary_key=true, autoincrement=true),
      @moonorm.column("email", TextType, nullable=false, unique=true),
      @moonorm.column("balance", RealType, nullable=false),
      @moonorm.column(
        "team_id",
        BigIntType,
        references=("teams", "id"),
        on_delete="SET NULL",
      ),
      @moonorm.column("status", TextType, nullable=false, default="'active'"),
      @moonorm.column("level", IntType, nullable=false, checks=["level >= 0"]),
    ],
    r => {
      id: r.read(0),
      email: r.read(1),
      balance: r.read(2),
      team_id: r.read(3),
      status: r.read(4),
      level: r.read(5),
    },
    a => {
      let out : Array[(String, @moondb.Value)] = []
      if a.id is Some(v) {
        out.push(("id", @moondb.Int64(v)))
      }
      out.push(("email", @moondb.Text(a.email)))
      out.push(("balance", @moondb.Double(a.balance)))
      out.push(
        (
          "team_id",
          match a.team_id {
            Some(v) => @moondb.Int64(v)
            None => @moondb.Null
          },
        ),
      )
      out.push(("status", @moondb.Text(a.status)))
      out.push(("level", @moondb.Int(a.level)))
      out
    },
  )
}
// --8<-- [end:model]

///|
pub fn ddl() -> String {
  @report.ddl(account())
}

///|
pub fn query() -> String {
  @report.query(account())
}

///|
pub fn insert() -> String {
  @report.insert(account(), {
    id: None,
    email: "ada@x.io",
    balance: 0.0,
    team_id: Some(2),
    status: "active",
    level: 1,
  })
}
