///|
/// `#orm.table` on a struct and `#orm.column` or `#orm.skip` on its fields,
/// turned into `T::model()`.
priv struct Orm {}

///|
impl @gen.Generator for Orm with fn name(_) {
  "moonorm"
}

///|
let table_spec : @attr.Spec = @attr.Spec::new("orm.table").optional("name", Str)

///|
let column_spec : @attr.Spec = @attr.Spec::new("orm.column")
  .optional("name", Str)
  .optional("kind", Str)
  .optional("primary_key", Bool)
  .optional("autoincrement", Bool)
  .optional("unique", Bool)
  .optional("default", Str)
  .many("check", Str)
  .optional("references", Str)
  .optional("on_delete", Str)
  .optional("on_update", Str)

///|
let skip_spec : @attr.Spec = @attr.Spec::new("orm.skip")

///|
/// Where `attr` is written, as `file:line:column`.
fn at(attr : @attribute.Attribute, file : String) -> String {
  "\{file}:\{attr.loc.start.lnum}:\{attr.loc.start.column()}"
}

///|
/// The `#orm.*` attributes among `attrs`. One that does not parse is refused here
/// rather than passed over, since `@attr.under` sees only those that parse.
fn orm_attrs(
  attrs : @list.List[@attribute.Attribute],
  file : String,
) -> Array[@attribute.Attribute] raise {
  for attr in attrs {
    if @attr.name_of(attr) is None && attr.raw.has_prefix("#orm.") {
      fail("\{at(attr, file)}: `\{attr.raw}` does not parse as an annotation")
    }
  }
  @attr.under(attrs, "orm")
}

///|
fn quoted(text : String) -> String {
  @quote.string(text).to_string()
}

///|
fn args_str(args : @attr.Args?, key : String) -> String? {
  match args {
    Some(a) => a.str(key)
    None => None
  }
}

///|
fn args_flag(args : @attr.Args?, key : String) -> Bool {
  match args {
    Some(a) => a.bool(key) is Some(true)
    None => false
  }
}

///|
/// A field as the column it declares: its name and the `field(...)` call. `None`
/// for a skipped field.
fn column(
  field : @gen.Field,
  where_ : String,
  file : String,
) -> (String, String)? raise {
  let mut col = None
  let mut skip = None
  for attr in orm_attrs(field.attrs, file) {
    match @attr.name_of(attr) {
      Some("orm.column") if col is None => col = Some(attr)
      Some("orm.skip") if skip is None => skip = Some(attr)
      Some("orm.column" | "orm.skip" as name) =>
        fail("\{at(attr, file)}: `#\{name}` is written twice")
      Some(name) =>
        fail("\{at(attr, file)}: `#\{name}` is not a moonorm field annotation")
      None => fail("\{at(attr, file)}: unnamed")
    }
  }
  if skip is Some(s) {
    ignore(skip_spec.bind(s))
    if col is Some(c) {
      fail("\{at(c, file)}: a skipped field takes no `#orm.column`")
    }
    return None
  }
  let where_ = match col {
    Some(c) => at(c, file)
    None => where_
  }
  let what = "field `\{field.name}`"
  let args = match col {
    Some(c) => Some(column_spec.bind(c))
    None => None
  }
  let (base, optional) = match inner_option(field.ty) {
    Some(inner) => (inner, true)
    None => (field.ty, false)
  }
  let col_type = match args_str(args, "kind") {
    Some(name) =>
      match column_named(name) {
        Some(c) => c
        None =>
          fail(
            "\{where_}: \{what}: `kind=\{quoted(name)}` is not a column type",
          )
      }
    None =>
      match column_of(base) {
        Some(c) => c
        None =>
          fail(
            "\{where_}: \{what}: `\{field.ty}` has no default column type; give `#orm.column(kind=...)`",
          )
      }
  }
  let name = args_str(args, "name").unwrap_or(field.name)
  let primary_key = args_flag(args, "primary_key")
  let autoincrement = args_flag(args, "autoincrement")
  if autoincrement {
    if !primary_key {
      fail("\{where_}: \{what}: `autoincrement` needs `primary_key=true`")
    }
    if !optional {
      fail(
        "\{where_}: \{what}: an autoincrement key is `\{field.ty}?`, `None` until the database assigns it",
      )
    }
    guard col_type is ("IntType" | "BigIntType") else {
      fail("\{where_}: \{what}: an autoincrement key is an integer")
    }
  }
  let parts = [quoted(name), col_type, "h => h.\{field.name}"]
  if primary_key {
    parts.push("primary_key=true")
  }
  if autoincrement {
    parts.push("autoincrement=true")
  }
  if !optional {
    parts.push("nullable=false")
  }
  if args_flag(args, "unique") {
    parts.push("unique=true")
  }
  if args_str(args, "default") is Some(d) {
    parts.push("default=\{quoted(d)}")
  }
  let checks = match args {
    Some(a) => a.strs("check")
    None => []
  }
  if !checks.is_empty() {
    parts.push("checks=[\{checks.map(quoted).join(", ")}]")
  }
  match args_str(args, "references") {
    Some(target) => {
      guard target.split(".").map(s => s.to_owned()).collect() is [t, c] &&
        !t.is_empty() &&
        !c.is_empty() else {
        fail("\{where_}: \{what}: `references` is `table.column`")
      }
      parts.push("references=(\{quoted(t)}, \{quoted(c)})")
    }
    None =>
      for key in ["on_delete", "on_update"] {
        if args_str(args, key) is Some(_) {
          fail("\{where_}: \{what}: `\{key}` needs `references`")
        }
      }
  }
  for key in ["on_delete", "on_update"] {
    if args_str(args, key) is Some(action) {
      parts.push("\{key}=\{quoted(action)}")
    }
  }
  Some((name, "@moonorm.field(\{parts.join(", ")})"))
}

///|
/// The model of one `#orm.table` struct: a private `let` holding it, so every
/// call hands out the same descriptor and a session's identity map keeps its
/// history, and `T::model()` returning it.
fn model(
  table : @attribute.Attribute,
  name : String,
  fields : Array[@gen.Field],
  public : Bool,
  file : String,
) -> String raise {
  let where_ = at(table, file)
  let args = table_spec.bind(table)
  let table_name = args.str("name").unwrap_or(snake(name))
  let calls = []
  let reads = []
  let names : Map[String, Unit] = Map([])
  for field in fields {
    match column(field, where_, file) {
      Some((column_name, call)) => {
        if names.contains(column_name) {
          fail("\{where_}: `\{name}` declares column `\{column_name}` twice")
        }
        names.set(column_name, ())
        reads.push("\{field.name}: r.read(\{calls.length()})")
        calls.push(call)
      }
      None => reads.push("\{field.name}: Default::default()")
    }
  }
  if calls.is_empty() {
    fail("\{where_}: `\{name}` declares no column")
  }
  let holder = snake(name) + "_model"
  let vis = if public { "pub " } else { "" }
  (
    $|let \{holder} : @moonorm.Model[\{name}] = @moonorm.Model::from_fields(
    $|  \{quoted(table_name)},
    $|  [\{calls.join(", ")}],
    $|  r => { \{reads.join(", ")} },
    $|)
    $|
    $|\{vis}fn \{name}::model() -> @moonorm.Model[\{name}] {
    $|  \{holder}
    $|}
  )
}

///|
impl @gen.Generator for Orm with fn generate(_, decls) {
  let models = []
  for decl in decls {
    match decl {
      Struct(name~, fields~, attrs~, public~, file~, ..) => {
        let found = orm_attrs(attrs, file)
        for attr in found {
          if @attr.name_of(attr) is Some(n) && n != "orm.table" {
            fail(
              "\{at(attr, file)}: `#\{n}` is not a moonorm struct annotation",
            )
          }
        }
        match found {
          [table] => models.push(model(table, name, fields, public, file))
          [_, second, ..] =>
            fail("\{at(second, file)}: `#orm.table` is written twice")
          [] =>
            for field in fields {
              if orm_attrs(field.attrs, file) is [first, ..] {
                fail(
                  "\{at(first, file)}: `\{name}` has no `#orm.table`, so its fields take no `#orm.*`",
                )
              }
            }
        }
      }
      Enum(attrs~, file~, ..) | Func(attrs~, file~, ..) =>
        if orm_attrs(attrs, file) is [first, ..] {
          fail("\{at(first, file)}: `#orm.table` goes on a struct")
        }
      Other(..) => ()
    }
  }
  @quote.items(models.join("\n\n")).render()
}
