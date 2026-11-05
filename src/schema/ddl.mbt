// Table and index DDL, rendered once for every caller. A model, a migration
// operation and the reflection snapshot all have to agree on how a table is spelled
// for a dialect, so the spelling lives here and everything else delegates.

///|
/// `CREATE TABLE` for a column list, rendered for `dialect`. A single primary key
/// stays inline; several become one table-level `PRIMARY KEY (a, b)` constraint,
/// since SQL allows only one inline key per table. MySQL gets the `ENGINE=InnoDB`
/// suffix it needs to honour foreign keys.
pub fn create_table_sql(
  name : String,
  columns : Array[Column],
  dialect : @query.Dialect,
  if_not_exists~ : Bool = false,
) -> String {
  let head = if if_not_exists {
    "CREATE TABLE IF NOT EXISTS "
  } else {
    "CREATE TABLE "
  }
  let pks = columns.filter(fn(c) { c.primary_key })
  let composite = pks.length() > 1
  let defs : Array[String] = []
  for c in columns {
    defs.push(c.ddl_for(dialect, inline_pk=!composite))
  }
  if composite {
    defs.push("PRIMARY KEY (" + pks.map(fn(c) { c.name }).join(", ") + ")")
  }
  let tail = if dialect is Mysql { " ENGINE=InnoDB" } else { "" }
  head + name + " (" + defs.join(", ") + ")" + tail
}

///|
/// `DROP TABLE`, with the idempotent form when `if_exists`.
pub fn drop_table_sql(name : String, if_exists~ : Bool = false) -> String {
  "DROP TABLE " + (if if_exists { "IF EXISTS " } else { "" }) + name
}

///|
/// The statement that adds one column. SQLite, PostgreSQL and MySQL share the
/// spelling, so the dialect is not consulted.
pub fn add_column_sql(
  table : String,
  column : Column,
  dialect : @query.Dialect,
) -> String {
  "ALTER TABLE " +
  table +
  " ADD COLUMN " +
  column.ddl_for(dialect, inline_pk=false)
}

///|
/// The statement that drops one column.
pub fn drop_column_sql(table : String, name : String) -> String {
  "ALTER TABLE " + table + " DROP COLUMN " + name
}

///|
/// `CREATE INDEX`. `if_not_exists` is emitted where the dialect accepts it; MySQL
/// has no such clause for an index, so it is dropped there rather than producing a
/// statement the server rejects.
pub fn create_index_sql(
  name : String,
  table : String,
  columns : Array[String],
  unique~ : Bool = false,
  if_not_exists~ : Bool = false,
  dialect~ : @query.Dialect = Sqlite,
) -> String {
  "CREATE " +
  (if unique { "UNIQUE " } else { "" }) +
  "INDEX " +
  (if if_not_exists && !(dialect is Mysql) { "IF NOT EXISTS " } else { "" }) +
  name +
  " ON " +
  table +
  " (" +
  columns.join(", ") +
  ")"
}

///|
/// `DROP INDEX`. SQLite and PostgreSQL name an index on its own; MySQL spells it
/// `DROP INDEX name ON table`, so there the table is part of the statement and leaving
/// it out raises rather than emitting SQL the server would reject.
pub fn drop_index_sql(
  name : String,
  table : String?,
  if_exists~ : Bool = false,
  dialect~ : @query.Dialect = Sqlite,
) -> String raise @moondb.DbError {
  let head = if if_exists { "DROP INDEX IF EXISTS " } else { "DROP INDEX " }
  match (dialect, table) {
    (Mysql, Some(t)) =>
      "DROP INDEX " +
      (if if_exists { "IF EXISTS " } else { "" }) +
      name +
      " ON " +
      t
    (Mysql, None) =>
      raise @moondb.QueryError(
        "MySQL drops an index with DROP INDEX name ON table: name the table " +
        name +
        " sits on",
      )
    _ => head + name
  }
}

///|
/// `ALTER TABLE … RENAME TO …`. All three dialects share it.
pub fn rename_table_sql(from : String, to : String) -> String {
  "ALTER TABLE " + from + " RENAME TO " + to
}

///|
/// `ALTER TABLE … RENAME COLUMN a TO b` (SQLite 3.25+, MySQL 8.0, PostgreSQL 8).
pub fn rename_column_sql(table : String, from : String, to : String) -> String {
  "ALTER TABLE " + table + " RENAME COLUMN " + from + " TO " + to
}
