// The façade: every subpackage's public surface re-exported as it was, so
// `@moonorm.X` is still the X it was before the split. Enum constructors do not
// travel through `pub using`, so a match on one names its subpackage:
// `@query.Dialect::Postgres`, not `@moonorm.Dialect::Postgres`.

///|
pub using @query {
  trait AsSource,
  type Delete,
  type Dialect,
  type Insert,
  type LockClause,
  type LockMode,
  type Nulls,
  type Order,
  type Predicate,
  type Select,
  type Source,
  type Table,
  type Update,
  case_,
  cast,
  delete,
  func,
  insert,
  select,
  update,
}

///|
pub using @schema {
  type Column,
  type ColumnType,
  type Field,
  type ManyToMany,
  type Model,
  type Relation,
  belongs_to,
  column,
  field,
  has_many,
  many_to_many,
}

///|
pub using @session {
  type IsolationLevel,
  type LostUpdate,
  type RowStream,
  type Savepoint,
  type Session,
  type TxOptions,
}

///|
pub using @migrate {
  type ColumnDiff,
  type Migration,
  type Migrator,
  diff_schema,
  index_ddl,
  reflect_columns,
  reflect_columns_mysql,
  reflect_columns_pg,
  reflect_table,
  reflect_table_for,
}

///|
pub using @moondb {type Value, trait ToValue, trait FromValue}
