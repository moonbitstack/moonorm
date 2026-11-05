// Reflecting a whole database: which tables exist, what columns they have, and which
// indexes sit on them. The query texts live here as functions so an async driver path
// (PostgreSQL over the wire) issues the same statements the synchronous path does, and
// the parsers are pure — a test can feed them recorded rows with no server at all.

///|
/// One index read back from a database: the table it belongs to, its name, its columns
/// in order, and whether it is unique. Reflection groups it into a `TableSpec` index.
pub(all) struct ReflectedIndex {
  table : String
  name : String
  columns : Array[String]
  unique : Bool
}

///|
/// The tables in the current SQLite database, excluding SQLite's own.
pub fn sqlite_tables_query() -> String {
  "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
}

///|
/// `PRAGMA table_info` for one table: `cid, name, type, notnull, dflt_value, pk`.
pub fn sqlite_columns_query(table : String) -> String raise @moondb.DbError {
  guard @query.is_ident(table) else {
    raise @moondb.QueryError("invalid table identifier: " + table)
  }
  "PRAGMA table_info(" + table + ")"
}

///|
/// `PRAGMA index_list` for one table: `seq, name, unique, origin, partial`. Only rows
/// with `origin = 'c'` are indexes the schema declared; `'u'` and `'pk'` are the
/// implicit ones a UNIQUE or PRIMARY KEY constraint creates, which have no name to
/// drop.
pub fn sqlite_index_list_query(table : String) -> String raise @moondb.DbError {
  guard @query.is_ident(table) else {
    raise @moondb.QueryError("invalid table identifier: " + table)
  }
  "PRAGMA index_list(" + table + ")"
}

///|
/// `PRAGMA index_info` for one index: `seqno, cid, name`.
pub fn sqlite_index_info_query(index : String) -> String raise @moondb.DbError {
  guard @query.is_ident(index) else {
    raise @moondb.QueryError("invalid index name: " + index)
  }
  "PRAGMA index_info(" + index + ")"
}

///|
/// The base tables in the current PostgreSQL schema.
pub fn postgres_tables_query() -> String {
  "SELECT table_name FROM information_schema.tables WHERE table_schema = current_schema() AND table_type = 'BASE TABLE' ORDER BY table_name"
}

///|
/// The columns of one PostgreSQL table, in declaration order. The table arrives as the
/// statement's only bound parameter, so this is the text alone.
pub fn postgres_columns_query() -> String {
  "SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_name = ? ORDER BY ordinal_position"
}

///|
/// Every index in the current PostgreSQL schema that was created as an index, one row
/// per indexed column: `tablename, indexname, is_unique, attname`.
///
/// PostgreSQL backs a PRIMARY KEY or UNIQUE constraint with an index, and those are not
/// indexes the schema declares — reporting them would make every key look like a stray
/// index autogenerate wants to drop.
pub fn postgres_indexes_query() -> String {
  "SELECT t.relname, i.relname, ix.indisunique AS is_unique, a.attname FROM pg_index ix JOIN pg_class i ON i.oid = ix.indexrelid JOIN pg_class t ON t.oid = ix.indrelid JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY (ix.indkey) WHERE t.relkind = 'r' AND t.relnamespace = current_schema::regnamespace AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = ix.indexrelid) ORDER BY t.relname, i.relname, array_position(ix.indkey, a.attnum)"
}

///|
/// The base tables in the current MySQL database.
pub fn mysql_tables_query() -> String {
  "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE' ORDER BY table_name"
}

///|
/// The columns of one MySQL table (`SHOW COLUMNS`): `Field, Type, Null, Key, Default,
/// Extra`.
pub fn mysql_columns_query(table : String) -> String raise @moondb.DbError {
  guard @query.is_ident(table) else {
    raise @moondb.QueryError("invalid table identifier: " + table)
  }
  "SHOW COLUMNS FROM " + table
}

///|
/// Every index in the current MySQL database, one row per indexed column:
/// `TABLE_NAME, INDEX_NAME, is_unique, COLUMN_NAME`. `NON_UNIQUE` is inverted in the
/// query so all three backends report the same thing in the same column.
pub fn mysql_indexes_query() -> String {
  "SELECT TABLE_NAME, INDEX_NAME, (NON_UNIQUE = 0) AS is_unique, COLUMN_NAME FROM information_schema.statistics WHERE table_schema = DATABASE() ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX"
}

///|
/// The table names in a result set whose first column is the name.
pub fn table_names_of(
  rows : Array[@moondb.Row],
) -> Array[String] raise @moondb.DbError {
  let out : Array[String] = []
  for row in rows {
    out.push(row.text(0))
  }
  out
}

///|
/// Read a column that may arrive as a boolean, an integer flag or its text, because
/// the three backends disagree about how to report a yes-or-no about an index.
fn flag_of(row : @moondb.Row, name : String) -> Bool raise @moondb.DbError {
  match row.by_name(name) {
    Some(@moondb.Bool(b)) => b
    Some(@moondb.Int(n)) => n != 0
    Some(@moondb.Int64(n)) => n != 0L
    Some(@moondb.Text(s)) => s == "1" || s == "t" || s == "true" || s == "YES"
    Some(_) => false
    None =>
      raise @moondb.QueryError(
        "reflection: the index rows have no column " + name,
      )
  }
}

///|
/// Group index rows — `(table, index, unique, column)`, one row per indexed column, in
/// column order — into indexes. The shape is the one `postgres_indexes_query` and
/// `mysql_indexes_query` return, so one parser serves both; SQLite builds the same
/// rows from its two pragmas.
pub fn indexes_of_rows(
  rows : Array[@moondb.Row],
) -> Array[ReflectedIndex] raise @moondb.DbError {
  let out : Array[ReflectedIndex] = []
  for row in rows {
    let table = row.text(0)
    let name = row.text(1)
    let unique = flag_of(row, "is_unique")
    let column = row.text(3)
    let existing = out
      .iter()
      .find_first(ix => ix.table == table && ix.name == name)
    match existing {
      Some(ix) => ix.columns.push(column)
      None => out.push({ table, name, columns: [column], unique, })
    }
  }
  out
}

///|
/// Reflect one SQLite table's columns, tolerating the pragma's own typing: SQLite
/// reports `notnull` and `pk` as integers, so those are read as integers rather than
/// through a boolean accessor.
fn sqlite_columns(
  driver : &@moondb.Driver,
  table : String,
) -> Array[@schema.Column] raise @moondb.DbError {
  reflect_columns(driver.query(sqlite_columns_query(table), []))
}

///|
/// Reflect one SQLite table's explicitly created indexes. The implicit indexes a
/// UNIQUE or PRIMARY KEY constraint creates are skipped: they are not part of the
/// declared schema, so reporting them would make every unique column look like a
/// change.
fn sqlite_indexes(
  driver : &@moondb.Driver,
  table : String,
) -> Array[ReflectedIndex] raise @moondb.DbError {
  let out : Array[ReflectedIndex] = []
  for row in driver.query(sqlite_index_list_query(table), []) {
    let origin = match row.by_name("origin") {
      Some(@moondb.Text(o)) => o
      _ => "c"
    }
    if origin != "c" {
      continue
    }
    let name = match row.by_name("name") {
      Some(@moondb.Text(n)) => n
      _ => ""
    }
    if name == "" {
      continue
    }
    let unique = flag_of(row, "unique")
    let columns : Array[String] = []
    for info in driver.query(sqlite_index_info_query(name), []) {
      match info.by_name("name") {
        Some(@moondb.Text(column)) => columns.push(column)
        _ => ()
      }
    }
    out.push({ table, name, columns, unique, })
  }
  out
}

///|
/// Reflect a whole database: every base table, its columns, and its indexes — the read
/// half of autogenerate, and what a round-trip test compares before and after.
///
/// The per-dialect query texts are public (`sqlite_tables_query` and friends) so a
/// driver reached over a network can issue the same statements and feed the same
/// parsers, which is how the PostgreSQL round trip runs without a synchronous driver.
pub fn reflect_schema(
  driver : &@moondb.Driver,
  dialect : @query.Dialect,
) -> @schema.Schema raise @moondb.DbError {
  let tables : Array[@schema.TableSpec] = []
  match dialect {
    Sqlite =>
      for name in table_names_of(driver.query(sqlite_tables_query(), [])) {
        tables.push({
          name,
          columns: sqlite_columns(driver, name),
          indexes: sqlite_indexes(driver, name).map(ix => {
            @schema.index(ix.columns, name=ix.name, unique=ix.unique)
          }),
        })
      }
    Postgres => {
      let indexes = indexes_of_rows(driver.query(postgres_indexes_query(), []))
      for name in table_names_of(driver.query(postgres_tables_query(), [])) {
        tables.push({
          name,
          columns: reflect_columns_pg(
            driver.query(postgres_columns_query(), [@moondb.Text(name)]),
          ),
          indexes: indexes
          .filter(ix => ix.table == name)
          .map(ix => @schema.index(ix.columns, name=ix.name, unique=ix.unique)),
        })
      }
    }
    Mysql => {
      let indexes = indexes_of_rows(driver.query(mysql_indexes_query(), []))
      for name in table_names_of(driver.query(mysql_tables_query(), [])) {
        tables.push({
          name,
          columns: reflect_columns_mysql(
            driver.query(mysql_columns_query(name), []),
          ),
          indexes: indexes
          .filter(ix => ix.table == name)
          .map(ix => @schema.index(ix.columns, name=ix.name, unique=ix.unique)),
        })
      }
    }
  }
  @schema.Schema::new(tables)
}
