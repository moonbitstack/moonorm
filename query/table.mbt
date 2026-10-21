///|
/// A lightweight table descriptor: a table `name` plus its known `columns`. It is
/// the hand-written stand-in for SQLAlchemy's `Table(...)` metadata object —
/// MoonBit has no reflection, so the schema is declared explicitly rather than
/// introspected. `select()` turns it into a `Select` with every column projected.
pub(all) struct Table {
  name : String
  columns : Array[String]
}

///|
/// Start a SELECT over this table with all of its declared `columns` projected
/// (an empty `columns` yields `SELECT *`, matching `select(name)`).
pub fn Table::select(self : Table) -> Select {
  let s = select(self.name)
  for c in self.columns {
    s.cols.push(c)
  }
  s
}
