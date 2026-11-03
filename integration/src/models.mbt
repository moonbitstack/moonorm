// The annotated model. `#orm.table` on the struct is the source; `models.g.mbt` is
// what `cmd/orm` generates from it — the same `Model::from_fields` a hand-written
// model builds. The id is an autoincrement key, so an insert leaves it `None` and the
// database assigns it.

///|
/// A widget. `id` is an autoincrement key (`Int64?`, `None` until inserted), `name`
/// is required text, and `qty` is an optional integer stored as `qty`.
#orm.table(name="widgets")
pub struct Widget {
  #orm.column(primary_key=true, autoincrement=true)
  id : Int64?
  name : String
  #orm.column(name="qty")
  qty : Int32?
}
