// The three operations the guide shows, written once against a `Model[T]`, so the
// three model styles can be compared by what they produce rather than by reading
// their source. The generator takes the marked regions as the guide's code and the
// `check` package compares the three styles' results.

// --8<-- [start:ddl]

///|
/// Render `CREATE TABLE` for the three dialects, one statement per line.
pub fn[T] ddl(model : @moonorm.Model[T]) -> String {
  model.create_table_sql_for(Sqlite) +
  "\n" +
  model.create_table_sql_for(Postgres) +
  "\n" +
  model.create_table_sql_for(Mysql)
}
// --8<-- [end:ddl]

// --8<-- [start:query]

///|
/// A filtered, ordered, capped SELECT — the statement and its bound params.
pub fn[T] query(model : @moonorm.Model[T]) -> String {
  let (sql, params) = model
    .select()
    .where_("email", "=", @moondb.Text("ada@x.io"))
    .order_by("level", Asc)
    .limit(10)
    .build()
  sql + "\n" + params_text(params)
}
// --8<-- [end:query]

// --8<-- [start:insert]

///|
/// An INSERT for one record; the params are the values bound, in order.
pub fn[T] insert(model : @moonorm.Model[T], row : T) -> String {
  let (sql, params) = model.insert_of(row).build_for(Postgres)
  sql + "\n" + params_text(params)
}
// --8<-- [end:insert]

// --8<-- [start:diff]

///|
/// Compare a declared table with a reflected one and report each difference.
pub fn diff() -> String {
  let declared : Array[@moonorm.Column] = [
    @moonorm.column("id", BigIntType, primary_key=true),
    @moonorm.column("email", TextType, nullable=false),
    @moonorm.column("balance", RealType),
    @moonorm.column("team_id", BigIntType),
    @moonorm.column("status", TextType),
    @moonorm.column("level", IntType),
  ]
  let reflected : Array[@moonorm.Column] = [
    @moonorm.column("id", BigIntType, primary_key=true),
    @moonorm.column("email", TextType, nullable=false),
  ]
  let diffs = @moonorm.diff_schema(declared, reflected, dialect=Postgres)
  let lines : Array[String] = []
  for d in diffs {
    match d {
      Added(name~, col_type~) =>
        lines.push("+ " + name + " " + col_type.sql_for(Postgres))
      Removed(name) => lines.push("- " + name)
      TypeChanged(name~, from~, to~) =>
        lines.push(
          "~ " +
          name +
          " " +
          from.sql_for(Postgres) +
          " -> " +
          to.sql_for(Postgres),
        )
    }
  }
  lines.join("\n")
}
// --8<-- [end:diff]

///|
fn value_text(v : @moondb.Value) -> String {
  match v {
    Null => "Null"
    Bool(b) => "Bool(" + (if b { "true" } else { "false" }) + ")"
    Int(n) => "Int(" + n.to_string() + ")"
    Int64(n) => "Int64(" + n.to_string() + ")"
    Double(d) => "Double(" + d.to_string() + ")"
    Text(s) => "Text(\"" + s + "\")"
    Blob(b) => "Blob(" + b.length().to_string() + " bytes)"
  }
}

///|
fn params_text(vals : Array[@moondb.Value]) -> String {
  "params: [" + vals.map(value_text).join(", ") + "]"
}
