// The migration half of the differential: one model change, read by two
// autogenerators.
//
// `integration/reference/alembic_ops.py` creates a database from the "before" schema
// below, hands Alembic the "after" one, and keeps the operations Alembic derives. This
// file derives the same operations with `autogenerate_changes` from the same two
// declarations, so the two lists are the answer to one question asked twice: a table
// and a column appear, a column and an index disappear, and one column's storage type
// changes.
//
// An operation is rendered as one line — `<kind>|<table>|<what>` — which is also the
// shape `alembic_ops.py` writes, so the comparison is on the operation and not on how
// either implementation spells it.

///|
/// A column of the "before" and "after" schemas, spelled once.
pub fn reference_column(
  name : String,
  col_type : @schema.ColumnType,
  primary_key~ : Bool = false,
  nullable~ : Bool = true,
  unique~ : Bool = false,
  autoincrement~ : Bool = false,
  default? : String,
  references? : (String, String),
  on_delete? : String,
) -> @schema.Column {
  @schema.column(
    name,
    col_type,
    primary_key~,
    autoincrement~,
    nullable~,
    unique~,
    default?,
    references?,
    on_delete?,
  )
}

///|
/// The schema the database is in before the change: `account` still has `nickname`,
/// `article` has no `subtitle`, and there is no `tag` table.
pub fn reference_before() -> Array[@schema.TableSpec] {
  [
    @schema.TableSpec::new(
      "account",
      [
        reference_column(
          "id",
          @schema.IntType,
          primary_key=true,
          autoincrement=true,
        ),
        reference_column("email", @schema.TextType, nullable=false, unique=true),
        reference_column("name", @schema.TextType, nullable=false),
        reference_column("nickname", @schema.TextType),
        reference_column("score", @schema.RealType, nullable=false, default="0"),
      ],
      indexes=[@schema.index(["name"], name="ix_account_name")],
    ),
    @schema.TableSpec::new(
      "article",
      [
        reference_column(
          "id",
          @schema.IntType,
          primary_key=true,
          autoincrement=true,
        ),
        reference_column(
          "account_id",
          @schema.IntType,
          nullable=false,
          references=("account", "id"),
          on_delete="CASCADE",
        ),
        reference_column("title", @schema.TextType, nullable=false),
        reference_column("body", @schema.TextType),
        reference_column(
          "published",
          @schema.BoolType,
          nullable=false,
          default="0",
        ),
      ],
      indexes=[@schema.index(["account_id"], name="ix_article_account_id")],
    ),
  ]
}

///|
/// The schema afterwards: `nickname` gone, `score` no longer real, `subtitle` and the
/// `tag` table added, one index replaced by another.
pub fn reference_after() -> Array[@schema.TableSpec] {
  [
    @schema.TableSpec::new("account", [
      reference_column(
        "id",
        @schema.IntType,
        primary_key=true,
        autoincrement=true,
      ),
      reference_column("email", @schema.TextType, nullable=false, unique=true),
      reference_column("name", @schema.TextType, nullable=false),
      reference_column(
        "score",
        @schema.NumericType,
        nullable=false,
        default="0",
      ),
    ]),
    @schema.TableSpec::new(
      "article",
      [
        reference_column(
          "id",
          @schema.IntType,
          primary_key=true,
          autoincrement=true,
        ),
        reference_column(
          "account_id",
          @schema.IntType,
          nullable=false,
          references=("account", "id"),
          on_delete="CASCADE",
        ),
        reference_column("title", @schema.TextType, nullable=false),
        reference_column("body", @schema.TextType),
        reference_column(
          "published",
          @schema.BoolType,
          nullable=false,
          default="0",
        ),
        reference_column("subtitle", @schema.TextType),
      ],
      indexes=[
        @schema.index(["account_id"], name="ix_article_account_id"),
        @schema.index(["title"], name="ix_article_title"),
      ],
    ),
    @schema.TableSpec::new("tag", [
      reference_column(
        "id",
        @schema.IntType,
        primary_key=true,
        autoincrement=true,
      ),
      reference_column("label", @schema.TextType, nullable=false),
    ]),
  ]
}

///|
/// One operation as the canonical line `alembic_ops.py` writes.
pub fn reference_op_line(op : @migrate.Op) -> String {
  match op {
    CreateTable(name~, ..) => "add_table|" + name
    DropTable(name~, ..) => "remove_table|" + name
    AddColumn(table~, column~) => "add_column|" + table + "|" + column.name
    DropColumn(table~, name~) => "remove_column|" + table + "|" + name
    AlterColumn(table~, name~, col_type~, ..) =>
      if col_type is Some(_) {
        "alter_type|" + table + "|" + name
      } else {
        "alter_nullable|" + table + "|" + name
      }
    CreateIndex(table~, name~, ..) => "add_index|" + table + "|" + name
    DropIndex(table~, name~, ..) =>
      "remove_index|" + table.unwrap_or("") + "|" + name
    _ => "other"
  }
}

///|
/// What this library derives for the change above.
pub fn reference_autogenerated_ops() -> Array[String] {
  let changes = @migrate.autogenerate_changes(
    reference_after(),
    reference_before(),
    dialect=Sqlite,
  )
  let lines = changes.map(c => reference_op_line(c.up))
  lines.sort_by(fn(a, b) { reference_compare(a, b) })
  lines
}

///|
/// The same change, read by Alembic's autogenerate and by ours: the two lists of
/// operations have to be the same list.
test "reference: the migration for one model change is the one Alembic derives" {
  assert_eq(
    reference_autogenerated_ops(),
    expected_lines(expected_reference_alembic_ops_text),
  )
}
