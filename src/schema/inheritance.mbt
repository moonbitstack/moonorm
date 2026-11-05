// Inheritance mapping — the three shapes a class hierarchy takes in a relational
// store, each expressed as one `Model` over one record type.
//
// SQLAlchemy derives these from Python inheritance and dispatches on the class at
// runtime, handing back subclass instances from a base query. MoonBit has neither
// inheritance nor a downcast, so the mapping is declared: a subclass is a `Model[T]`
// that carries its own predicate (single table), its own join (joined table), or its
// own table outright (concrete table). The record type is what decides which columns
// exist, and the model decides which rows and which tables they come from.

///|
/// A nullable text column named `name`. Used for the discriminator a single-table
/// subclass adds when the base did not declare one; built as a literal because the
/// `column` constructor is shadowed by this file's `column~` parameter.
fn text_column(name : String) -> Column {
  {
    name,
    col_type: TextType,
    primary_key: false,
    autoincrement: false,
    nullable: true,
    unique: false,
    default: None,
    checks: [],
    references: None,
    on_delete: None,
    on_update: None,
  }
}

///|
/// A single-table subclass: the table is shared with its base, and a discriminator
/// column tells the rows apart. The returned model
///
/// * filters every read to `column = identity`,
/// * forces `column = identity` into every insert, so a subclass row cannot be
///   written as a base row by accident, and
/// * declares the discriminator column if the base already does — adding it to the
///   column list only when it is missing.
///
/// The base's own model stays as it was and reads every row of the table; a subclass
/// model reads only its own. This is the mapping SQLAlchemy spells `polymorphic_on`
/// plus `polymorphic_identity`.
pub fn[T] Model::discriminate(
  self : Model[T],
  column~ : String,
  identity~ : String,
) -> Model[T] {
  let columns = self.columns.copy()
  let mut declared = false
  for c in columns {
    if c.name == column {
      declared = true
    }
  }
  if !declared {
    columns.push(text_column(column))
  }
  let forced : @moondb.Value = @moondb.Text(identity)
  let inner = self.to_columns
  {
    table: self.table,
    columns,
    from_row: self.from_row,
    to_columns: fn(record : T) -> Array[(String, @moondb.Value)] {
      let out = inner(record)
      let mut present = false
      for pair in out {
        if pair.0 == column {
          present = true
        }
      }
      if !present {
        out.push((column, forced))
      }
      out
    },
    indexes: self.indexes,
    filter: [(column, forced)],
    joins: self.joins.copy(),
    projection: self.projection.copy(),
    parent: self.parent,
    ident: Map([]),
  }
}

///|
/// The column both tables of a joined mapping share: the parent's primary key, which
/// the subclass row's foreign key points at. Falls back to the first parent column,
/// and then to the first declared column, so a mapping with no declared key still has
/// a deterministic join rather than an index error.
fn[T] Model::key_of(self : Model[T], parent_columns : Array[String]) -> String {
  for name in parent_columns {
    for c in self.columns {
      if c.name == name && c.primary_key {
        return name
      }
    }
  }
  if parent_columns.length() > 0 {
    parent_columns[0]
  } else if self.columns.length() > 0 {
    self.columns[0].name
  } else {
    ""
  }
}

///|
/// A joined-table subclass: the base's columns live in `parent_table`, this class's
/// own columns in the model's table, and one row is the join of the two on the
/// primary key. The returned model
///
/// * projects `parent_table`'s columns qualified, then this table's, so `from_row`
///   reads the parent's half before the subclass's — the order the columns were
///   declared in,
/// * joins `parent_table` on `<parent_table>.<key> = <table>.<fk>`, and
/// * splits writes: an insert writes the parent row first, then the subclass row
///   carrying the same key, which is the only order the foreign key allows.
///
/// `fk` names the subclass column that references the parent key; it defaults to the
/// parent key's own name, which is the usual `id` in both tables.
pub fn[T] Model::joined(
  self : Model[T],
  parent_table~ : String,
  parent_columns~ : Array[String],
  fk? : String,
) -> Model[T] {
  let key = self.key_of(parent_columns)
  let fk_column = fk.unwrap_or(key)
  let projection : Array[String] = []
  for c in self.columns {
    if parent_columns.contains(c.name) {
      projection.push(parent_table + "." + c.name)
    } else {
      projection.push(self.table + "." + c.name)
    }
  }
  {
    table: self.table,
    columns: self.columns,
    from_row: self.from_row,
    to_columns: self.to_columns,
    indexes: self.indexes,
    filter: self.filter.copy(),
    joins: [
      (
        parent_table,
        parent_table + "." + key + " = " + self.table + "." + fk_column,
      ),
    ],
    projection,
    parent: Some((parent_table, parent_columns, fk_column)),
    ident: Map([]),
  }
}

///|
/// Split a record's bound columns into one group per table it is written to: one
/// `(table, columns)` pair for a plain model, and parent-then-subclass for a joined
/// mapping. The subclass group carries the foreign key even though the key column
/// belongs to the parent, because the subclass row is what holds the reference.
///
/// The order is the order the rows must be written in: a foreign key means the
/// parent row has to exist first.
pub fn[T] Model::split_columns(
  self : Model[T],
  columns : Array[(String, @moondb.Value)],
) -> Array[(String, Array[(String, @moondb.Value)])] {
  match self.parent {
    None => [(self.table, columns)]
    Some((parent_table, parent_columns, fk)) => {
      let key = self.parent_key()
      let mut key_value : @moondb.Value = Null
      for pair in columns {
        if pair.0 == key {
          key_value = pair.1
        }
      }
      let parent : Array[(String, @moondb.Value)] = []
      let child : Array[(String, @moondb.Value)] = []
      for pair in columns {
        if parent_columns.contains(pair.0) {
          parent.push(pair)
        } else {
          child.push(pair)
        }
      }
      let mut has_fk = false
      for pair in child {
        if pair.0 == fk {
          has_fk = true
        }
      }
      if !has_fk {
        child.push((fk, key_value))
      }
      [(parent_table, parent), (self.table, child)]
    }
  }
}

///|
/// The parent key column of a joined-table subclass — the column both tables share,
/// which the child's foreign key points at. Empty for a plain model.
pub fn[T] Model::parent_key(self : Model[T]) -> String {
  match self.parent {
    None => ""
    Some((_, parent_columns, _)) => self.key_of(parent_columns)
  }
}

///|
/// Whether this model's rows are split across two tables (a joined-table subclass).
pub fn[T] Model::is_joined(self : Model[T]) -> Bool {
  self.parent is Some(_)
}

///|
/// The table a joined-table subclass's parent half lives in, or `""`.
pub fn[T] Model::parent_table(self : Model[T]) -> String {
  match self.parent {
    None => ""
    Some((table, _, _)) => table
  }
}

///|
/// The subclass column that references the parent key, or `""`.
pub fn[T] Model::parent_fk(self : Model[T]) -> String {
  match self.parent {
    None => ""
    Some((_, _, fk)) => fk
  }
}
