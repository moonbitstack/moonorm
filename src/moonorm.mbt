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
  type Hybrid,
  type Predicate,
  type Select,
  type Source,
  type Table,
  type Update,
  case_,
  cast,
  delete,
  func,
  hybrid,
  insert,
  select,
  update,
}

///|
pub using @schema {
  type Column,
  type ColumnType,
  type CustomColumnType,
  type Field,
  type Index,
  type LoadStrategy,
  type ManyToMany,
  type Model,
  type Relation,
  type Schema,
  type TableSpec,
  belongs_to,
  column,
  custom_column_type,
  field,
  index,
  has_many,
  many_to_many,
  user_type,
}

///|
pub using @session {
  type AsyncRowStream,
  type AsyncSavepoint,
  type AsyncSession,
  type HookContext,
  type HookEvent,
  type IsolationLevel,
  type LostUpdate,
  type RowStream,
  type Savepoint,
  type Session,
  type TxOptions,
}

///|
pub using @migrate {
  type Change,
  type ColumnDiff,
  type HistoryEntry,
  type Migration,
  type Migrator,
  type Op,
  type ReflectedIndex,
  type Revision,
  type Statement,
  type Step,
  add_column,
  add_foreign_key,
  alter_column,
  autogenerate,
  autogenerate_changes,
  autogenerate_revision,
  create_index,
  create_table,
  diff_schema,
  drop_column,
  drop_foreign_key,
  drop_index,
  drop_table,
  execute,
  index_ddl,
  indexes_of_rows,
  mysql_columns_query,
  mysql_indexes_query,
  mysql_tables_query,
  postgres_columns_query,
  postgres_indexes_query,
  postgres_tables_query,
  rebuild_table,
  reflect_columns,
  reflect_columns_mysql,
  reflect_columns_pg,
  reflect_schema,
  reflect_table,
  reflect_table_for,
  rename_column,
  revision_bases,
  revision_heads,
  revisions_table_sql,
  rename_table,
  sqlite_columns_query,
  sqlite_index_info_query,
  sqlite_index_list_query,
  sqlite_tables_query,
  table_names_of,
}

///|
pub using @engine {type Dsn, type DsnError, type Engine, parse_dsn}

///|
pub using @moondb {type Value, trait ToValue, trait FromValue}
