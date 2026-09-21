///|
/// Schema DDL from declared columns: `Model::create_table_sql` (SQLite affinities) and
/// `create_table_sql_for` for PostgreSQL and MySQL, covering autoincrement idioms
/// (`AUTOINCREMENT` / `SERIAL` / `AUTO_INCREMENT`), `UNIQUE`, `DEFAULT`, column `CHECK`,
/// foreign keys with `ON DELETE`/`ON UPDATE`, and a composite primary key rendered as a
/// table-level constraint. Also a lone `Column::ddl`, `ColumnType::sql_for` across
/// dialects, and `index_ddl`. All identifiers are trusted, declared in code — never bound.
///
///     moon run examples/10-schema-ddl
struct Hero {
  id : Int
  name : String
  team_id : Int
}

///|
let heroes : @moonorm.Model[Hero] = @moonorm.Model::new(
  "heroes",
  [
    @moonorm.column(
      "id",
      @moonorm.IntType,
      primary_key=true,
      autoincrement=true,
    ),
    @moonorm.column(
      "name",
      @moonorm.VarcharType(64),
      nullable=false,
      unique=true,
    ),
    @moonorm.column("power", @moonorm.IntType, default="0", checks=[
      "power >= 0",
    ]),
    @moonorm.column(
      "team_id",
      @moonorm.IntType,
      references=("teams", "id"),
      on_delete="CASCADE",
    ),
    @moonorm.column(
      "created",
      @moonorm.DateTimeType,
      default="CURRENT_TIMESTAMP",
    ),
  ],
  r => { id: r.int(0), name: r.text(1), team_id: r.int(3), },
  h => {
    [
      ("id", @moondb.Int(h.id)),
      ("name", @moondb.Text(h.name)),
      ("team_id", @moondb.Int(h.team_id)),
    ]
  },
)

///|
/// A composite-key association table: the primary key spans two columns, so it lands
/// as a table-level `PRIMARY KEY (a, b)` constraint rather than inline.
let memberships : @moonorm.Model[Hero] = @moonorm.Model::new(
  "memberships",
  [
    @moonorm.column("hero_id", @moonorm.IntType, primary_key=true),
    @moonorm.column("team_id", @moonorm.IntType, primary_key=true),
  ],
  r => { id: r.int(0), name: "", team_id: r.int(1), },
  _ => [],
)

///|
#coverage.skip
fn main {
  println("-- CREATE TABLE (SQLite affinities)")
  println(heroes.create_table_sql())
  println("")
  println("-- CREATE TABLE (PostgreSQL)")
  println(heroes.create_table_sql_for(@moonorm.Postgres))
  println("")
  println("-- CREATE TABLE (MySQL)")
  println(heroes.create_table_sql_for(@moonorm.Mysql))
  println("")
  println("-- idempotent DDL (IF NOT EXISTS)")
  println(heroes.create_table_sql(if_not_exists=true))

  // One column on its own, and the type keyword each dialect renders.
  let fk = @moonorm.column(
    "team_id",
    @moonorm.IntType,
    nullable=false,
    references=("teams", "id"),
    on_update="RESTRICT",
  )
  println("")
  println("-- one Column::ddl")
  println(fk.ddl())
  println("-- ColumnType::sql_for across dialects")
  for
    t in [
      ("uuid", @moonorm.UuidType),
      ("json", @moonorm.JsonType),
      ("bool", @moonorm.BoolType),
      ("real", @moonorm.RealType),
    ] {
    let name = t.0
    let ty = t.1
    println(
      "  \{name}: sqlite=\{ty.sql_for(@moonorm.Sqlite)} pg=\{ty.sql_for(@moonorm.Postgres)} mysql=\{ty.sql_for(@moonorm.Mysql)}",
    )
  }

  println("")
  println("-- composite primary key -> table-level constraint")
  println(memberships.create_table_sql())

  println("")
  println("-- index_ddl")
  println(@moonorm.index_ddl("idx_heroes_name", "heroes", ["name"]))
  println(
    @moonorm.index_ddl(
      "uq_membership",
      "memberships",
      ["hero_id", "team_id"],
      unique=true,
    ),
  )
}
