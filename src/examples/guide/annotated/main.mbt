// --8<-- [start:accessor]

///|
/// The generator writes `Account::model()`; this names it the way the rest of the
/// guide does.
fn account() -> @moonorm.Model[Account] {
  Account::model()
}
// --8<-- [end:accessor]

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
