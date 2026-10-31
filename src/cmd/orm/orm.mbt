///|
/// `#orm.table` on a struct, with `#orm.index`, `#orm.has_many` and
/// `#orm.belongs_to` beside it, and `#orm.column` or `#orm.skip` on its fields,
/// turned into `T::model()` and one function per relation.
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
  .optional("index", Bool)

///|
let index_spec : @attr.Spec = @attr.Spec::new("orm.index")
  .many("column", Str)
  .optional("name", Str)
  .optional("unique", Bool)

///|
/// A relation on a struct: `name` is the function it becomes, `target` the
/// struct on the other side and `foreign_key` the column that links them.
let has_many_spec : @attr.Spec = @attr.Spec::new("orm.has_many")
  .required("name", Str)
  .required("target", Str)
  .required("foreign_key", Str)
  .optional("key", Str)

///|
let belongs_to_spec : @attr.Spec = @attr.Spec::new("orm.belongs_to")
  .required("name", Str)
  .required("target", Str)
  .required("foreign_key", Str)
  .optional("key", Str)

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
/// A field as the column it declares: its name, the `field(...)` call, and
/// whether it asks for an index of its own. `None` for a skipped field.
fn column(
  field : @gen.Field,
  where_ : String,
  file : String,
) -> (String, String, Bool)? raise {
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
  let indexed = args_flag(args, "index")
  if indexed && (args_flag(args, "unique") || primary_key) {
    fail(
      "\{where_}: \{what}: a unique or primary key column is indexed already",
    )
  }
  Some((name, "@moonorm.field(\{parts.join(", ")})", indexed))
}

///|
/// What a model holds that another model's relation needs: its column names by
/// field, and the fields of its primary key.
priv struct Shape {
  columns : Map[String, String]
  keys : Array[String]
}

///|
/// The model of one `#orm.table` struct: a private `let` holding it, so every
/// call hands out the same descriptor and a session's identity map keeps its
/// history, and `T::model()` returning it; then its indexes, and a function
/// for each relation.
fn model(
  table : @attribute.Attribute,
  extras : Array[@attribute.Attribute],
  name : String,
  fields : Array[@gen.Field],
  public : Bool,
  file : String,
  shapes : Map[String, Shape],
) -> String raise {
  let where_ = at(table, file)
  let args = table_spec.bind(table)
  let table_name = args.str("name").unwrap_or(snake(name))
  let calls = []
  let reads = []
  let indexes = []
  let names : Map[String, Unit] = Map([])
  for field in fields {
    match column(field, where_, file) {
      Some((column_name, call, indexed)) => {
        if names.contains(column_name) {
          fail("\{where_}: `\{name}` declares column `\{column_name}` twice")
        }
        names.set(column_name, ())
        reads.push("\{field.name}: r.read(\{calls.length()})")
        calls.push(call)
        if indexed {
          indexes.push("@moonorm.index([\{quoted(column_name)}])")
        }
      }
      None => reads.push("\{field.name}: Default::default()")
    }
  }
  if calls.is_empty() {
    fail("\{where_}: `\{name}` declares no column")
  }
  let shape = shapes.get(name).unwrap()
  let vis = if public { "pub " } else { "" }
  let relations = []
  for extra in extras {
    let here = at(extra, file)
    match @attr.name_of(extra) {
      Some("orm.index") => {
        let a = index_spec.bind(extra)
        let columns = a.strs("column")
        if columns.is_empty() {
          fail("\{here}: `#orm.index` names at least one `column`")
        }
        for c in columns {
          if !names.contains(c) {
            fail("\{here}: `\{name}` has no column `\{c}`")
          }
        }
        let parts = ["[\{columns.map(quoted).join(", ")}]"]
        if a.str("name") is Some(n) {
          parts.push("name=\{quoted(n)}")
        }
        if a.bool("unique") is Some(true) {
          parts.push("unique=true")
        }
        indexes.push("@moonorm.index(\{parts.join(", ")})")
      }
      Some("orm.has_many") => {
        let a = has_many_spec.bind(extra)
        let target = a.str("target").unwrap()
        let key = match a.str("key") {
          Some(k) => k
          None =>
            match shape.keys {
              [k] => k
              _ =>
                fail(
                  "\{here}: `\{name}` has no single primary key; give `key=`",
                )
            }
        }
        if !shape.columns.contains(key) {
          fail("\{here}: `\{name}` has no mapped field `\{key}`")
        }
        relations.push(
          (
            $|\{vis}fn \{name}::\{a.str("name").unwrap()}() -> @moonorm.Relation[\{name}, \{target}] {
            $|  @moonorm.has_many(\{target}::model(), \{quoted(a.str("foreign_key").unwrap())}, h => h.\{key})
            $|}
          ),
        )
      }
      Some("orm.belongs_to") => {
        let a = belongs_to_spec.bind(extra)
        let target = a.str("target").unwrap()
        let field = a.str("foreign_key").unwrap()
        if !shape.columns.contains(field) {
          fail("\{here}: `\{name}` has no mapped field `\{field}`")
        }
        let key = match a.str("key") {
          Some(k) => k
          None =>
            match shapes.get(target) {
              Some({ keys: [k], columns, }) => columns.get(k).unwrap()
              Some(_) =>
                fail(
                  "\{here}: `\{target}` has no single primary key; give `key=`",
                )
              None =>
                fail("\{here}: `\{target}` is not annotated here; give `key=`")
            }
        }
        relations.push(
          (
            $|\{vis}fn \{name}::\{a.str("name").unwrap()}() -> @moonorm.Relation[\{name}, \{target}] {
            $|  @moonorm.belongs_to(\{target}::model(), \{quoted(key)}, h => h.\{field})
            $|}
          ),
        )
      }
      _ => ()
    }
  }
  let holder = snake(name) + "_model"
  let index_arg = if indexes.is_empty() {
    ""
  } else {
    "\n  indexes=[\{indexes.join(", ")}],"
  }
  let code =
    $|let \{holder} : @moonorm.Model[\{name}] = @moonorm.Model::from_fields(
    $|  \{quoted(table_name)},
    $|  [\{calls.join(", ")}],
    $|  r => { \{reads.join(", ")} },\{index_arg}
    $|)
    $|
    $|\{vis}fn \{name}::model() -> @moonorm.Model[\{name}] {
    $|  \{holder}
    $|}
  ([code] + relations).join("\n\n")
}

///|
/// The shape of a struct's model as far as relations need it: each mapped
/// field's column name, and the fields of its primary key.
fn shape_of(fields : Array[@gen.Field], file : String) -> Shape raise {
  let columns = Map([])
  let keys = []
  for field in fields {
    let attrs = orm_attrs(field.attrs, file)
    if attrs.iter().any(a => @attr.name_of(a) is Some("orm.skip")) {
      continue
    }
    let mut column_name = field.name
    for a in attrs {
      if @attr.name_of(a) is Some("orm.column") {
        let args = column_spec.bind(a)
        column_name = args.str("name").unwrap_or(field.name)
        if args.bool("primary_key") is Some(true) {
          keys.push(field.name)
        }
      }
    }
    columns[field.name] = column_name
  }
  { columns, keys, }
}

///|
impl @gen.Generator for Orm with fn generate(_, decls) {
  let shapes = Map([])
  for decl in decls {
    if decl is Struct(name~, fields~, attrs~, file~, ..) &&
      orm_attrs(attrs, file)
      .iter()
      .any(a => @attr.name_of(a) is Some("orm.table")) {
      shapes[name] = shape_of(fields, file)
    }
  }
  let models = []
  for decl in decls {
    match decl {
      Struct(name~, fields~, attrs~, public~, file~, ..) => {
        let all = orm_attrs(attrs, file)
        let extras = []
        let found = []
        for attr in all {
          match @attr.name_of(attr) {
            Some("orm.table") => found.push(attr)
            Some("orm.index" | "orm.has_many" | "orm.belongs_to") =>
              extras.push(attr)
            Some(n) =>
              fail(
                "\{at(attr, file)}: `#\{n}` is not a moonorm struct annotation",
              )
            None => ()
          }
        }
        if found.is_empty() && extras is [first, ..] {
          fail("\{at(first, file)}: `\{name}` has no `#orm.table`")
        }
        match found {
          [table] =>
            models.push(
              model(table, extras, name, fields, public, file, shapes),
            )
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
