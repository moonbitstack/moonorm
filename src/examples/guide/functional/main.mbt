// --8<-- [start:model]

///|
/// The same account table built from a field list.
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
  @moonorm.Model::from_fields(
    "accounts",
    [
      @moonorm.field(
        "id",
        BigIntType,
        a => a.id,
        primary_key=true,
        autoincrement=true,
      ),
      @moonorm.field(
        "email",
        TextType,
        a => a.email,
        nullable=false,
        unique=true,
      ),
      @moonorm.field("balance", RealType, a => a.balance, nullable=false),
      @moonorm.field(
        "team_id",
        BigIntType,
        a => a.team_id,
        references=("teams", "id"),
        on_delete="SET NULL",
      ),
      @moonorm.field(
        "status",
        TextType,
        a => a.status,
        nullable=false,
        default="'active'",
      ),
      @moonorm.field("level", IntType, a => a.level, nullable=false, checks=[
        "level >= 0",
      ]),
    ],
    r => {
      id: r.read(0),
      email: r.read(1),
      balance: r.read(2),
      team_id: r.read(3),
      status: r.read(4),
      level: r.read(5),
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
