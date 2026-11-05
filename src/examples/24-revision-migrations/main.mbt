// Revision migrations, end to end and without a database: a branched history is
// applied, reported, rolled back and stamped, the offline SQL a deployment would run
// is printed, and autogenerate turns a declared schema into the operations that bring
// a reflected one in line.
//
//     moon run examples/24-revision-migrations
//
// The driver models only the revisions bookkeeping table. It records the schema
// statements a revision runs so the example can print them; the Migrator itself is the
// same one that runs against SQLite, PostgreSQL and MySQL.

///|
struct Ledger {
  mut applied : Array[String]
  schema : Array[String]
  mut transactions : Int32
}

///|
fn text_of(value : @moondb.Value) -> String {
  match value {
    Text(s) => s
    _ => ""
  }
}

///|
impl @moondb.Driver for Ledger with fn execute(
  self : Ledger,
  sql : String,
  params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  if sql.has_prefix("INSERT INTO moonorm_revisions") {
    self.applied.push(text_of(params[0]))
  } else if sql.has_prefix("DELETE FROM moonorm_revisions") {
    let gone = text_of(params[0])
    self.applied = self.applied.filter(id => id != gone)
  } else {
    self.schema.push(sql)
  }
  { rows_affected: 1L, last_insert_id: 0L, }
}

///|
impl @moondb.Driver for Ledger with fn query(
  self : Ledger,
  sql : String,
  _params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  if sql.contains("SELECT id FROM moonorm_revisions") {
    self.applied.map(id => { columns: ["id"], values: [@moondb.Text(id)], })
  } else {
    []
  }
}

///|
impl @moondb.Driver for Ledger with fn begin(self : Ledger) -> Unit raise @moondb.DbError {
  self.transactions = self.transactions + 1
}

///|
impl @moondb.Driver for Ledger with fn commit(_self : Ledger) -> Unit raise @moondb.DbError {

}

///|
impl @moondb.Driver for Ledger with fn rollback(_self : Ledger) -> Unit raise @moondb.DbError {

}

///|
impl @moondb.Driver for Ledger with fn close(_self : Ledger) -> Unit {

}

///|
/// One revision that creates a table named after itself, so the printed statements say
/// which revision they came from.
fn step(
  id : String,
  parents : Array[String],
  name : String,
) -> @moonorm.Revision {
  let columns = [
    @moonorm.column("id", @schema.IntType, primary_key=true),
    @moonorm.column("name", @schema.TextType),
  ]
  @moonorm.Revision::new(
    id~,
    parents~,
    name~,
    up=[@moonorm.create_table(id, columns)],
    down=[@moonorm.drop_table(id)],
  )
}

///|
fn print_history(entries : Array[@moonorm.HistoryEntry]) -> Unit {
  for entry in entries {
    let mark = if entry.applied { "*" } else { " " }
    println("  \{mark} \{entry.id}  \{entry.name}")
  }
}

///|
fn main {
  // A history with a branch: 0002 and 0003 both follow 0001, and 0004 merges them.
  let history = [
    step("0001", [], "create heroes"),
    step("0002", ["0001"], "create teams"),
    step("0003", ["0001"], "create cities"),
    step("0004", ["0002", "0003"], "merge"),
  ]
  let ledger = { applied: [], schema: [], transactions: 0, }
  let sess = @moonorm.Session::new(ledger)
  try {
    let migrator = @moonorm.Migrator::new()
    println(
      "heads of the history: " + @moonorm.revision_heads(history).join(", "),
    )
    println("")
    println("upgrade to heads:")
    let applied = migrator.upgrade(sess, history, target="heads")
    println("  applied " + applied.join(", "))
    println("  heads now: " + migrator.heads(sess, history).join(", "))
    println("  transactions: \{ledger.transactions}")
    println("")
    println("history:")
    print_history(migrator.history(sess, history))
    println("")
    println("downgrade to 0002 (drops the branch tip and the merge):")
    let undone = migrator.downgrade(sess, history, target="0002")
    println("  undone " + undone.join(", "))
    println("  heads now: " + migrator.heads(sess, history).join(", "))
    println("")
    println("offline SQL for a fresh database, as a deployment would print it:")
    for
      steppe in migrator.upgrade_sql(
        history,
        [],
        target="heads",
        dialect=@moonorm.Dialect::Postgres,
      ) {
      for statement in steppe.statements {
        println("  " + statement.sql)
      }
    }
    println("")
    // Autogenerate: the model declares a column and an index the database does not have.
    let declared = @moonorm.TableSpec::new(
      "heroes",
      [
        @moonorm.column("id", @schema.IntType, primary_key=true),
        @moonorm.column("name", @schema.TextType, nullable=false),
        @moonorm.column("power", @schema.IntType),
      ],
      indexes=[@moonorm.index(["name"], name="ix_heroes_name")],
    )
    let reflected = @moonorm.TableSpec::new("heroes", [
      @moonorm.column("id", @schema.IntType, primary_key=true),
      @moonorm.column("name", @schema.TextType, nullable=false),
    ])
    println("autogenerate, and the operations that undo it:")
    for change in @moonorm.autogenerate_changes([declared], [reflected]) {
      println("  up:   " + change.up.to_sql(@moonorm.Dialect::Sqlite)[0])
      println("  down: " + change.down.to_sql(@moonorm.Dialect::Sqlite)[0])
    }
    sess.close()
  } catch {
    error => println("migration error: " + error.to_string())
  }
}
