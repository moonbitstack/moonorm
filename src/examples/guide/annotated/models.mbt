// --8<-- [start:model]

///|
/// The account table as annotations. `id` is an autoincrement key, so an insert
/// leaves it `None`; `T?` is nullable and `T` is `NOT NULL`.
#orm.table(name="accounts")
pub struct Account {
  #orm.column(primary_key=true, autoincrement=true)
  id : Int64?
  #orm.column(unique=true)
  email : String
  balance : Double
  #orm.column(references="teams.id", on_delete="SET NULL")
  team_id : Int64?
  #orm.column(default="'active'")
  status : String
  #orm.column(check="level >= 0")
  level : Int32
}
// --8<-- [end:model]
