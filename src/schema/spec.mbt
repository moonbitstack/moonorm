// A table as data, and a whole schema as data. A `Model` is a typed mapping over
// one table; a `TableSpec` is the same table without the record type, which is what
// autogenerate compares and what a model tree feeds it. Reflection produces the same
// shape, so a declared schema and a live one diff as two values.

///|
/// One table described by its columns and indexes — the record-type-free view of a
/// `Model`. Two `TableSpec`s are what a schema comparison needs: a name, the ordered
/// columns, and the indexes on them.
pub(all) struct TableSpec {
  name : String
  columns : Array[Column]
  indexes : Array[Index]
}

///|
/// Describe a table.
pub fn TableSpec::new(
  name : String,
  columns : Array[Column],
  indexes~ : Array[Index] = [],
) -> TableSpec {
  { name, columns, indexes, }
}

///|
/// A set of tables — a declared metadata tree, or everything reflected off a
/// database. The unit autogenerate compares and the unit a snapshot renders.
pub(all) struct Schema {
  tables : Array[TableSpec]
}

///|
/// A schema from its tables.
pub fn Schema::new(tables : Array[TableSpec]) -> Schema {
  { tables, }
}

///|
/// The table named `name`, or `None`.
pub fn Schema::table(self : Schema, name : String) -> TableSpec? {
  self.tables.iter().find_first(t => t.name == name)
}

///|
/// The table names, in order.
pub fn Schema::names(self : Schema) -> Array[String] {
  self.tables.map(t => t.name)
}

///|
/// Name order, the one a reader expects of a sorted list: compare the characters and
/// let the first difference decide, then the shorter name first. `String::compare`
/// orders by length before content, which would put `ab` after `b`, so the snapshot
/// compares the names itself.
fn name_order(a : String, b : String) -> Int32 {
  let left = a.length()
  let right = b.length()
  let common = if left < right { left } else { right }
  for i = 0; i < common; i = i + 1 {
    let x = a[i].to_int()
    let y = b[i].to_int()
    if x != y {
      return if x < y { -1 } else { 1 }
    }
  }
  if left < right {
    -1
  } else if left > right {
    1
  } else {
    0
  }
}

///|
/// A normalised text rendering of the schema, for comparing two snapshots of the same
/// database. Column types are written as `dialect` spells them, so an `Int64` and an
/// `Int` both reflected as `INTEGER` on SQLite compare equal — the physical structure
/// is what a round trip has to preserve, not the declared vocabulary.
///
/// Lines are `table`, then one `column` line per column in order, then one `index`
/// line per index sorted by name, so a diff points at the table and the line that
/// changed. Tables are sorted by name for the same reason.
pub fn Schema::snapshot(self : Schema, dialect : @query.Dialect) -> String {
  let ordered = self.tables.copy()
  ordered.sort_by(fn(a, b) { name_order(a.name, b.name) })
  let lines : Array[String] = []
  for t in ordered {
    lines.push("table " + t.name)
    for c in t.columns {
      let mut line = "  column " +
        c.name +
        " " +
        c.col_type.sql_for(dialect) +
        (if c.nullable { " null" } else { " not null" })
      if c.primary_key {
        line = line + " pk"
      }
      if c.autoincrement {
        line = line + " auto"
      }
      lines.push(line)
    }
    let indexes = t.indexes.copy()
    indexes.sort_by(fn(a, b) { name_order(index_name(t, a), index_name(t, b)) })
    for ix in indexes {
      lines.push(
        "  index " +
        index_name(t, ix) +
        (if ix.unique { " unique" } else { "" }) +
        " (" +
        ix.columns.join(", ") +
        ")",
      )
    }
  }
  lines.join("\n")
}

///|
/// The name of an index, applying the same default the DDL uses: `ix_<table>_<cols>`,
/// or `uq_` when unique.
pub fn index_name(table : TableSpec, ix : Index) -> String {
  match ix.name {
    Some(n) => n
    None =>
      (if ix.unique { "uq_" } else { "ix_" }) +
      table.name +
      "_" +
      ix.columns.join("_")
  }
}

///|
/// This model's table as a `TableSpec` — the bridge from a typed model to the schema
/// data autogenerate compares.
pub fn[T] Model::spec(self : Model[T]) -> TableSpec {
  { name: self.table, columns: self.columns, indexes: self.indexes, }
}
