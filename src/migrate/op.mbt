// A schema operation as data. A revision lists the operations that apply it, and the
// runner renders them for whichever dialect it is talking to — which is what makes
// one revision apply on SQLite, PostgreSQL and MySQL, and what lets the same list be
// rendered to SQL text for an offline run.
//
// SQLAlchemy spells this namespace `op.create_table(...)`; here an operation is a
// value returned by `create_table(...)`, so it can also be compared, printed, and
// stored before anything renders it.

///|
/// One schema change. `AlterColumn` carries only what changes, so a rename is a
/// rename rather than a full column redefinition; `RebuildTable` is SQLite's batch
/// alter, where the column set is supplied whole because the engine cannot alter a
/// column in place.
pub(all) enum Op {
  CreateTable(
    name~ : String,
    columns~ : Array[@schema.Column],
    if_not_exists~ : Bool
  )
  DropTable(name~ : String, if_exists~ : Bool)
  AddColumn(table~ : String, column~ : @schema.Column)
  DropColumn(table~ : String, name~ : String)
  RenameTable(from~ : String, to~ : String)
  RenameColumn(table~ : String, from~ : String, to~ : String)
  AlterColumn(
    table~ : String,
    name~ : String,
    new_name~ : String?,
    col_type~ : @schema.ColumnType?,
    nullable~ : Bool?,
    default~ : String?,
    drop_default~ : Bool
  )
  AddForeignKey(
    table~ : String,
    name~ : String,
    columns~ : Array[String],
    ref_table~ : String,
    ref_columns~ : Array[String],
    on_delete~ : String?,
    on_update~ : String?
  )
  DropForeignKey(table~ : String, name~ : String)
  CreateIndex(
    name~ : String,
    table~ : String,
    columns~ : Array[String],
    unique~ : Bool,
    if_not_exists~ : Bool
  )
  DropIndex(name~ : String, table~ : String?, if_exists~ : Bool)
  RebuildTable(
    name~ : String,
    columns~ : Array[@schema.Column],
    copy~ : Array[String]
  )
  Execute(sql~ : String)
}

///|
/// Create a table from its column list.
pub fn create_table(
  name : String,
  columns : Array[@schema.Column],
  if_not_exists~ : Bool = false,
) -> Op {
  CreateTable(name~, columns~, if_not_exists~)
}

///|
/// Drop a table, optionally tolerating its absence.
pub fn drop_table(name : String, if_exists~ : Bool = false) -> Op {
  DropTable(name~, if_exists~)
}

///|
/// Add one column.
pub fn add_column(table : String, column : @schema.Column) -> Op {
  AddColumn(table~, column~)
}

///|
/// Drop one column.
pub fn drop_column(table : String, name : String) -> Op {
  DropColumn(table~, name~)
}

///|
/// Rename a table.
pub fn rename_table(from : String, to : String) -> Op {
  RenameTable(from~, to~)
}

///|
/// Rename a column. Every dialect here spells this `RENAME COLUMN`, so it is the one
/// column change that does not need a table rebuild on SQLite.
pub fn rename_column(table : String, from : String, to : String) -> Op {
  RenameColumn(table~, from~, to~)
}

///|
/// Change a column: its name, its type, its nullability, or its default. Only the
/// parts given are rendered. SQLite cannot change a type or a nullability in place,
/// so that combination raises and points at `rebuild_table`.
pub fn alter_column(
  table : String,
  name : String,
  new_name? : String,
  col_type? : @schema.ColumnType,
  nullable? : Bool,
  default? : String,
  drop_default~ : Bool = false,
) -> Op {
  AlterColumn(
    table~,
    name~,
    new_name~,
    col_type~,
    nullable~,
    default~,
    drop_default~,
  )
}

///|
/// Add a foreign-key constraint to an existing table. SQLite cannot add one without
/// rebuilding the table, so it raises there.
pub fn add_foreign_key(
  table : String,
  name : String,
  columns : Array[String],
  ref_table : String,
  ref_columns : Array[String],
  on_delete? : String,
  on_update? : String,
) -> Op {
  AddForeignKey(
    table~,
    name~,
    columns~,
    ref_table~,
    ref_columns~,
    on_delete~,
    on_update~,
  )
}

///|
/// Drop a foreign-key constraint by name.
pub fn drop_foreign_key(table : String, name : String) -> Op {
  DropForeignKey(table~, name~)
}

///|
/// Create an index.
pub fn create_index(
  name : String,
  table : String,
  columns : Array[String],
  unique~ : Bool = false,
  if_not_exists~ : Bool = false,
) -> Op {
  CreateIndex(name~, table~, columns~, unique~, if_not_exists~)
}

///|
/// Drop an index. `table` matters on MySQL, which names an index as `table.index`.
pub fn drop_index(
  name : String,
  table? : String,
  if_exists~ : Bool = false,
) -> Op {
  DropIndex(name~, table~, if_exists~)
}

///|
/// SQLite's batch alter: build the table again from `columns`, carrying over the
/// listed `copy` columns, and swap it in. Indexes on the old table are dropped with
/// it, so pair this with the `create_index` operations that re-establish them.
pub fn rebuild_table(
  name : String,
  columns : Array[@schema.Column],
  copy : Array[String],
) -> Op {
  RebuildTable(name~, columns~, copy~)
}

///|
/// Run SQL verbatim. For the changes the operation set does not model — a trigger, an
/// engine-specific clause — and for data migrations.
pub fn execute(sql : String) -> Op {
  Execute(sql~)
}

///|
/// The name of the table an operation touches, for ordering and reporting.
pub fn Op::table(self : Op) -> String {
  match self {
    CreateTable(name~, ..) => name
    DropTable(name~, ..) => name
    AddColumn(table~, ..) => table
    DropColumn(table~, ..) => table
    RenameTable(from~, ..) => from
    RenameColumn(table~, ..) => table
    AlterColumn(table~, ..) => table
    AddForeignKey(table~, ..) => table
    DropForeignKey(table~, ..) => table
    CreateIndex(table~, ..) => table
    DropIndex(..) => ""
    RebuildTable(name~, ..) => name
    Execute(..) => ""
  }
}

///|
/// The name of the temporary table `RebuildTable` builds before swapping it in.
fn batch_table(name : String) -> String {
  "moonorm_batch_" + name
}

///|
/// The statements this operation is, rendered for `dialect`. Most are one statement;
/// `AlterColumn` is several when more than one property changes, and `RebuildTable`
/// is the four-step swap SQLite needs.
///
/// Raises rather than emitting something the engine would reject: SQLite cannot add
/// or drop a foreign key or change a column's type in place, and `rebuild_table` is
/// the wrong tool for PostgreSQL and MySQL, which alter in place. The error names the
/// engine and points at the operation that does work.
pub fn Op::to_sql(
  self : Op,
  dialect : @query.Dialect,
) -> Array[String] raise @moondb.DbError {
  match self {
    CreateTable(name~, columns~, if_not_exists~) =>
      [@schema.create_table_sql(name, columns, dialect, if_not_exists~)]
    DropTable(name~, if_exists~) => [@schema.drop_table_sql(name, if_exists~)]
    AddColumn(table~, column~) =>
      [@schema.add_column_sql(table, column, dialect)]
    DropColumn(table~, name~) => [@schema.drop_column_sql(table, name)]
    RenameTable(from~, to~) => [@schema.rename_table_sql(from, to)]
    RenameColumn(table~, from~, to~) =>
      [@schema.rename_column_sql(table, from, to)]
    AlterColumn(
      table~,
      name~,
      new_name~,
      col_type~,
      nullable~,
      default~,
      drop_default~
    ) =>
      alter_column_sql(
        table, name, new_name, col_type, nullable, default, drop_default, dialect,
      )
    AddForeignKey(
      table~,
      name~,
      columns~,
      ref_table~,
      ref_columns~,
      on_delete~,
      on_update~
    ) => {
      if dialect is Sqlite {
        raise @moondb.QueryError(
          "SQLite cannot add a foreign key to an existing table: rebuild " +
          table +
          " with the constraint declared on the column",
        )
      }
      let mut s = "ALTER TABLE " +
        table +
        " ADD CONSTRAINT " +
        name +
        " FOREIGN KEY (" +
        columns.join(", ") +
        ") REFERENCES " +
        ref_table +
        " (" +
        ref_columns.join(", ") +
        ")"
      match on_delete {
        Some(act) => s = s + " ON DELETE " + act
        None => ()
      }
      match on_update {
        Some(act) => s = s + " ON UPDATE " + act
        None => ()
      }
      [s]
    }
    DropForeignKey(table~, name~) =>
      match dialect {
        Sqlite =>
          raise @moondb.QueryError(
            "SQLite cannot drop a foreign key in place: rebuild " + table,
          )
        Postgres => ["ALTER TABLE " + table + " DROP CONSTRAINT " + name]
        Mysql => ["ALTER TABLE " + table + " DROP FOREIGN KEY " + name]
      }
    CreateIndex(name~, table~, columns~, unique~, if_not_exists~) =>
      [
        @schema.create_index_sql(
          name,
          table,
          columns,
          unique~,
          if_not_exists~,
          dialect~,
        ),
      ]
    DropIndex(name~, table~, if_exists~) =>
      [@schema.drop_index_sql(name, table, if_exists~, dialect~)]
    RebuildTable(name~, columns~, copy~) => {
      if !(dialect is Sqlite) {
        raise @moondb.QueryError(
          "rebuild_table is SQLite's batch alter; " +
          name +
          " can be altered in place on " +
          (if dialect is Postgres { "PostgreSQL" } else { "MySQL" }),
        )
      }
      let tmp = batch_table(name)
      let out : Array[String] = [
        @schema.create_table_sql(tmp, columns, dialect),
      ]
      if copy.length() > 0 {
        let list = copy.join(", ")
        out.push(
          "INSERT INTO " +
          tmp +
          " (" +
          list +
          ") SELECT " +
          list +
          " FROM " +
          name,
        )
      }
      out.push(@schema.drop_table_sql(name))
      out.push(@schema.rename_table_sql(tmp, name))
      out
    }
    Execute(sql~) => [sql]
  }
}

///|
/// `ALTER COLUMN`, spelled the way each engine spells it. A rename is a separate
/// statement everywhere; a type, a nullability and a default are one statement on
/// PostgreSQL and one `MODIFY COLUMN` on MySQL, and impossible in place on SQLite.
fn alter_column_sql(
  table : String,
  name : String,
  new_name : String?,
  col_type : @schema.ColumnType?,
  nullable : Bool?,
  default : String?,
  drop_default : Bool,
  dialect : @query.Dialect,
) -> Array[String] raise @moondb.DbError {
  let column = new_name.unwrap_or(name)
  let out : Array[String] = []
  if new_name is Some(_) {
    out.push(@schema.rename_column_sql(table, name, column))
  }
  match dialect {
    Postgres => {
      if col_type is Some(t) {
        out.push(
          "ALTER TABLE " +
          table +
          " ALTER COLUMN " +
          column +
          " TYPE " +
          t.sql_for(Postgres),
        )
      }
      if nullable is Some(allow) {
        out.push(
          "ALTER TABLE " +
          table +
          " ALTER COLUMN " +
          column +
          (if allow { " DROP NOT NULL" } else { " SET NOT NULL" }),
        )
      }
      if drop_default {
        out.push(
          "ALTER TABLE " + table + " ALTER COLUMN " + column + " DROP DEFAULT",
        )
      } else if default is Some(expr) {
        out.push(
          "ALTER TABLE " +
          table +
          " ALTER COLUMN " +
          column +
          " SET DEFAULT " +
          expr,
        )
      }
    }
    Mysql => {
      // `MODIFY COLUMN` restates the whole definition, so it needs the type; anything
      // else the server would have to guess, and guessing resets it.
      if col_type is Some(t) {
        let mut s = "ALTER TABLE " +
          table +
          " MODIFY COLUMN " +
          column +
          " " +
          t.sql_for(Mysql)
        if nullable is Some(allow) {
          s = s + (if allow { " NULL" } else { " NOT NULL" })
        }
        if default is Some(expr) {
          s = s + " DEFAULT " + expr
        }
        out.push(s)
      } else if nullable is Some(_) || default is Some(_) {
        raise @moondb.QueryError(
          "MySQL restates a column to change its nullability or default; give alter_column a col_type for " +
          table +
          "." +
          column,
        )
      }
      if drop_default {
        out.push(
          "ALTER TABLE " + table + " ALTER COLUMN " + column + " DROP DEFAULT",
        )
      }
    }
    Sqlite =>
      if col_type is Some(_) ||
        nullable is Some(_) ||
        default is Some(_) ||
        drop_default {
        raise @moondb.QueryError(
          "SQLite cannot change a column's type, nullability or default in place: rebuild " +
          table +
          " with rebuild_table",
        )
      }
  }
  out
}
