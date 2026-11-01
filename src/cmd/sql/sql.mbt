// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// `#sql.select`, `#sql.insert`, `#sql.update` and `#sql.delete` on a `declare fn`,
/// with `#sql.results` beside them, turned into the function's body.
priv struct Sql {}

///|
impl @gen.Generator for Sql with fn name(_) {
  "moonorm sql"
}

///|
fn statement_spec(name : String) -> @attr.Spec {
  @attr.Spec::new(name)
  .positional("sql", Str)
  .optional("dialect", Str)
  .optional("returning", Str)
}

///|
let results_spec : @attr.Spec = @attr.Spec::new("sql.results")
  .required("column", Str)
  .required("field", Str)

///|
/// Where `attr` is written, as `file:line:column`.
fn at(attr : @attribute.Attribute, file : String) -> String {
  "\{file}:\{attr.loc.start.lnum}:\{attr.loc.start.column()}"
}

///|
fn sql_attrs(
  attrs : @list.List[@attribute.Attribute],
  file : String,
) -> Array[@attribute.Attribute] raise {
  for attr in attrs {
    if @attr.name_of(attr) is None && attr.raw.has_prefix("#sql.") {
      fail("\{at(attr, file)}: `\{attr.raw}` does not parse as an annotation")
    }
  }
  @attr.under(attrs, "sql")
}

///|
fn quoted(text : String) -> String {
  @quote.string(text).to_string()
}

///|
/// The struct literal or the value one row reads into.
fn row_value(
  ty : String,
  structs : Map[String, Array[@gen.Field]],
  renames : Map[String, String],
  columns : Array[String]?,
  where_ : String,
) -> String raise {
  if is_scalar(ty) {
    if !renames.is_empty() {
      fail(
        "\{where_}: `#sql.results` renames a struct's fields, and this is \{ty}",
      )
    }
    return "@mapper.first(row)"
  }
  guard structs.get(ty) is Some(fields) else {
    fail(
      "\{where_}: `\{ty}` is neither a column type nor a struct in the files read",
    )
  }
  for field, _ in renames {
    if !fields.iter().any(f => f.name == field) {
      fail("\{where_}: `\{ty}` has no field `\{field}`")
    }
  }
  let parts = []
  for field in fields {
    let name = renames.get(field.name).unwrap_or(field.name)
    if columns is Some(selected) &&
      !selected.contains(name) &&
      optional_of(field.ty) is None {
      fail(
        "\{where_}: `\{ty}.\{field.name}` needs a column `\{name}`, and the query selects \{selected.join(", ")}",
      )
    }
    parts.push("\{field.name}: @mapper.column(row, \{quoted(name)})")
  }
  "{ \{parts.join(", ")} }"
}

///|
/// A function's parameters as its signature wrote them.
fn signature(params : Array[@gen.Param], where_ : String) -> String raise {
  let parts = []
  for param in params {
    guard param.name is Some(name) && param.ty is Some(ty) else {
      fail("\{where_}: every parameter needs a name and a type")
    }
    // The parser's span for a trait object starts after the ampersand.
    let ty = if ty is ("@moondb.Driver" | "@moondb.AsyncDriver") {
      "&" + ty
    } else {
      ty
    }
    match param.pass {
      Positional => parts.push("\{name} : \{ty}")
      Labelled => parts.push("\{name}~ : \{ty}")
      _ => fail("\{where_}: `\{name}` cannot be optional")
    }
  }
  parts.join(", ")
}

///|
/// The parameter the statement runs on.
fn driver_of(
  params : Array[@gen.Param],
  is_async : Bool,
  where_ : String,
) -> String raise {
  for param in params {
    match param.ty {
      Some("&@moondb.Driver" | "@moondb.Driver") => {
        if is_async {
          fail(
            "\{where_}: a `&@moondb.Driver` is not async; declare a plain `fn`",
          )
        }
        return param.name.unwrap()
      }
      Some("&@moondb.AsyncDriver" | "@moondb.AsyncDriver") => {
        if !is_async {
          fail("\{where_}: a `&@moondb.AsyncDriver` needs `declare async fn`")
        }
        return param.name.unwrap()
      }
      _ => ()
    }
  }
  fail(
    "\{where_}: no parameter is a `&@moondb.Driver` or `&@moondb.AsyncDriver`",
  )
}

///|
/// What a `#sql.select` does with the rows.
fn read_rows(
  returns : String,
  structs : Map[String, Array[@gen.Field]],
  renames : Map[String, String],
  columns : Array[String]?,
  where_ : String,
) -> String raise {
  match (inside(returns, "Array["), optional_of(returns)) {
    (Some(item), _) => {
      let value = row_value(item, structs, renames, columns, where_)
      "rows.map(row => \{value})"
    }
    (_, Some(item)) => {
      let value = row_value(item, structs, renames, columns, where_)
      "match @mapper.optional(rows) { Some(row) => Some(\{value}); None => None }"
    }
    _ => {
      let value = row_value(returns, structs, renames, columns, where_)
      "let row = @mapper.one(rows)\n  \{value}"
    }
  }
}

///|
/// What an `#sql.insert`, `#sql.update` or `#sql.delete` gives back without
/// `returning`: nothing, how many rows it touched, or for an insert the new id.
fn read_result(
  kind : String,
  returns : String?,
  where_ : String,
) -> String raise {
  match (kind, returns) {
    (_, None | Some("Unit")) => "ignore(result)"
    ("sql.insert", Some("Int64")) => "result.last_insert_id"
    (_, Some("Int64")) => "result.rows_affected"
    (_, Some(other)) =>
      fail("\{where_}: this returns `Unit` or `Int64`, not `\{other}`")
  }
}

///|
/// The body of one annotated `declare fn`.
fn body_of(
  note : @attribute.Attribute,
  kind : String,
  renames : Map[String, String],
  params : Array[@gen.Param],
  returns : String?,
  is_async : Bool,
  structs : Map[String, Array[@gen.Field]],
  file : String,
) -> String raise {
  let where_ = at(note, file)
  let args = statement_spec(kind).bind(note)
  let dialect = args.str("dialect").unwrap_or("sqlite")
  guard dialect is ("sqlite" | "postgres" | "mysql") else {
    fail("\{where_}: `dialect` is sqlite, postgres or mysql, not `\{dialect}`")
  }
  let db = driver_of(params, is_async, where_)
  let names = params.filter_map(p => p.name)
  let source = args.str("sql").unwrap()
  let (statement, paths) = bind_values(source, dialect, names, where_)
  let returning = args.str("returning")
  if returning is Some(_) && kind != "sql.insert" {
    fail("\{where_}: `returning` is for `#sql.insert`")
  }
  if returning is Some(_) && dialect == "mysql" {
    fail(
      "\{where_}: MySQL has no RETURNING; leave it out, and an `Int64` return is the new id",
    )
  }
  if !renames.is_empty() && kind != "sql.select" {
    fail("\{where_}: `#sql.results` is for `#sql.select`")
  }
  let bound = paths.map(p => "@moondb.ToValue::to_value(\{p})").join(", ")
  match (kind, returning) {
    ("sql.select", _) => {
      guard returns is Some(returned) && returned != "Unit" else {
        fail("\{where_}: a select returns what it reads")
      }
      let read = read_rows(
        returned,
        structs,
        renames,
        selected(statement),
        where_,
      )
      (
        $|  let rows = \{db}.query(\{quoted(statement)}, [\{bound}])
        $|  \{read}
      )
    }
    (_, Some(column)) => {
      guard returns is Some(returned) else {
        fail("\{where_}: `returning` needs a return type")
      }
      let value = row_value(returned, structs, Map([]), None, where_)
      let full = quoted("\{statement} RETURNING \{column}")
      (
        $|  let rows = \{db}.query(\{full}, [\{bound}])
        $|  let row = @mapper.one(rows)
        $|  \{value}
      )
    }
    _ => {
      let read = read_result(kind, returns, where_)
      (
        $|  let result = \{db}.execute(\{quoted(statement)}, [\{bound}])
        $|  \{read}
      )
    }
  }
}

///|
impl @gen.Generator for Sql with fn generate(_, decls) {
  let structs : Map[String, Array[@gen.Field]] = Map([])
  for decl in decls {
    if decl is Struct(name~, fields~, ..) {
      structs[name] = fields
    }
  }
  let out = []
  for decl in decls {
    match decl {
      Func(
        name~,
        params~,
        returns~,
        is_async~,
        attrs~,
        public~,
        file~,
        raw~,
        ..
      ) => {
        let found = sql_attrs(attrs, file)
        if found.is_empty() {
          continue
        }
        let statements = []
        let renames : Map[String, String] = Map([])
        for attr in found {
          match @attr.name_of(attr) {
            Some(
              "sql.select"
              | "sql.insert"
              | "sql.update"
              | "sql.delete" as kind
            ) => statements.push((attr, kind))
            Some("sql.results") => {
              let a = results_spec.bind(attr)
              renames[a.str("field").unwrap()] = a.str("column").unwrap()
            }
            Some(other) =>
              fail("\{at(attr, file)}: `#\{other}` is not a moonorm annotation")
            None => ()
          }
        }
        guard statements is [(note, kind)] else {
          fail(
            "\{at(found[0], file)}: `\{name}` needs exactly one statement annotation",
          )
        }
        let where_ = at(note, file)
        guard raw is TopFuncDef(fun_decl~, decl_body=DeclNone, ..) else {
          fail(
            "\{where_}: `#sql.*` goes on a `declare fn`, which it gives a body",
          )
        }
        let raises = match fun_decl.error_type {
          DefaultErrorType(..) => "raise"
          ErrorType(..) => "raise @moondb.DbError"
          _ =>
            fail(
              "\{where_}: a statement can fail; declare `\{name}` with `raise`",
            )
        }
        let body = body_of(
          note, kind, renames, params, returns, is_async, structs, file,
        )
        let vis = if public { "pub " } else { "" }
        let run = if is_async { "async " } else { "" }
        let result = match returns {
          Some(ty) => " -> \{ty}"
          None => ""
        }
        out.push(
          (
            $|\{vis}\{run}fn \{name}(\{signature(params, where_)})\{result} \{raises} {
            $|\{body}
            $|}
          ),
        )
      }
      Struct(attrs~, file~, ..) | Enum(attrs~, file~, ..) =>
        if sql_attrs(attrs, file) is [first, ..] {
          fail("\{at(first, file)}: `#sql.*` goes on a `declare fn`")
        }
      Other(..) => ()
    }
  }
  @quote.items(out.join("\n\n")).render()
}
