// A canonical description of a SQLite file, read back through SQLite's own pragmas
// rather than from this library's model. It is the same set of lines the SQLAlchemy
// reference writes, so the two schemas can be compared line for line.
//
// What is compared is what a query can observe: the storage class (SQLite's affinity,
// so `BIGINT` and `INTEGER` agree), whether a column can be null, whether it is part
// of the key, its default, the indexes the declaration asked for and the foreign keys
// with their actions. Spelling that no query can see — an inline `INTEGER PRIMARY KEY
// AUTOINCREMENT` versus a table-level `PRIMARY KEY` over a `NOT NULL` column — is
// normalised away in the same three places the reference normalises it.

///|
/// SQLite's own rule for what a declared type stores as (the type-affinity table in
/// its documentation): the declared words decide, not the framework that wrote them.
pub fn reference_affinity(declared : String) -> String {
  let ty = declared.to_upper()
  if ty.contains("INT") {
    return "integer"
  }
  if ty.contains("CHAR") || ty.contains("CLOB") || ty.contains("TEXT") {
    return "text"
  }
  if ty == "" || ty.contains("BLOB") {
    return "blob"
  }
  if ty.contains("REAL") || ty.contains("FLOA") || ty.contains("DOUB") {
    return "real"
  }
  "numeric"
}

///|
/// A column default as both sides spell it. SQLite keeps the default as the text it
/// was given, so `DEFAULT 0` and `DEFAULT '0'` arrive as `0` and `'0'`; on a numeric
/// column those are one value, and the quote is not something a query can tell apart.
pub fn reference_default(v : @moondb.Value, kind : String) -> String {
  let text = match v {
    @moondb.Null => return "-"
    @moondb.Text(s) => s
    other => other.to_string()
  }
  if (kind == "integer" || kind == "real" || kind == "numeric") &&
    text.length() >= 2 &&
    text[0] == '\'' &&
    text[text.length() - 1] == '\'' {
    return text.exact_view(start=1, end=text.length() - 1).to_owned()
  }
  text
}

///|
/// A referential action the way the reference writes it: lower case, words joined by
/// a dash.
pub fn reference_action(v : @moondb.Value) -> String {
  let text = match v {
    @moondb.Text(s) => s.to_lower()
    _ => return "-"
  }
  if text == "" {
    return "-"
  }
  let out = text.replace_all(old=" ", new="-")
  if out == "" {
    "-"
  } else {
    out
  }
}

///|
/// Code-point order, which is what Python's `sorted` uses on these lines. The
/// language's own `String::compare` orders by length first, so both sides of the
/// differential would otherwise write the same facts in two different orders.
pub fn reference_compare(a : String, b : String) -> Int32 {
  let left = a.length()
  let right = b.length()
  let common = if left < right { left } else { right }
  for i = 0; i < common; i = i + 1 {
    let x = a[i].to_int()
    let y = b[i].to_int()
    if x != y {
      return if x < y { -1 } else { 1 }
    }
  }
  if left < right {
    -1
  } else if left > right {
    1
  } else {
    0
  }
}

///|
/// The schema of the database `sess` is connected to, one line per fact, sorted so a
/// difference shows up as a line rather than as an offset.
pub fn reference_snapshot(
  sess : @session.Session,
) -> Array[String] raise @moondb.DbError {
  let lines : Array[String] = []
  for row in sess.query(@migrate.sqlite_tables_query(), []) {
    let table = row.text(0)
    for c in sess.query("PRAGMA table_info(" + table + ")", []) {
      let kind = reference_affinity(c.text(2))
      let pk = c.int(5) != 0
      lines.push(
        "column|" +
        table +
        "|" +
        c.text(1) +
        "|" +
        kind +
        "|" +
        (if c.int(3) != 0 || pk { "not-null" } else { "nullable" }) +
        "|" +
        (if pk { "pk" } else { "-" }) +
        "|" +
        reference_default(c.get(4), kind),
      )
    }
    for ix in sess.query("PRAGMA index_list(" + table + ")", []) {
      let name = ix.text(1)
      let origin = ix.text(3)
      if origin == "pk" {
        // The key's own index; the column lines already carry the key.
        continue
      }
      let columns : Array[String] = []
      for info in sess.query("PRAGMA index_info(" + name + ")", []) {
        match info.get(2) {
          @moondb.Text(column) => columns.push(column)
          _ => ()
        }
      }
      lines.push(
        "index|" +
        table +
        "|" +
        (if origin == "u" { "@unique" } else { name }) +
        "|" +
        (if ix.int(2) != 0 { "unique" } else { "-" }) +
        "|" +
        columns.join(","),
      )
    }
    for fk in sess.query("PRAGMA foreign_key_list(" + table + ")", []) {
      let target = match fk.get(4) {
        @moondb.Text(t) => t
        _ => "id"
      }
      lines.push(
        "fk|" +
        table +
        "|" +
        fk.text(3) +
        "|" +
        fk.text(2) +
        "|" +
        target +
        "|" +
        reference_action(fk.get(6)) +
        "|" +
        reference_action(fk.get(5)),
      )
    }
  }
  lines.sort_by(fn(a, b) { reference_compare(a, b) })
  lines
}
