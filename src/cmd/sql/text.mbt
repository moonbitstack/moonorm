// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The placeholder the `n`th bound value takes, from 1.
fn placeholder(dialect : String, n : Int32) -> String {
  if dialect == "postgres" {
    "$\{n}"
  } else {
    "?"
  }
}

///|
fn is_name(text : String) -> Bool {
  if text.is_empty() {
    return false
  }
  for i, c in text.to_array() {
    let letter = c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    if !letter && !(i > 0 && c >= '0' && c <= '9') {
      return false
    }
  }
  true
}

///|
/// A statement with every `#{path}` turned into a bound value: the SQL for
/// `dialect`, and the paths in the order they bind. A quoted string is left as it
/// is, so `'#{x}'` is text. There is no `${x}`: nothing is ever spliced into the
/// statement, and a placeholder written by hand would not line up with the values.
fn bind_values(
  text : String,
  dialect : String,
  names : Array[String],
  where_ : String,
) -> (String, Array[String]) raise {
  let chars = text.to_array()
  let out = StringBuilder()
  let paths = []
  let mut quote : Char? = None
  let mut i = 0
  while i < chars.length() {
    let c = chars[i]
    if quote is Some(q) {
      out.write_char(c)
      if c == q {
        quote = None
      }
      i = i + 1
      continue
    }
    let next = if i + 1 < chars.length() { Some(chars[i + 1]) } else { None }
    match (c, next) {
      ('\'' | '"' | '`', _) => {
        quote = Some(c)
        out.write_char(c)
        i = i + 1
      }
      ('#', Some('{')) => {
        let mut end = i + 2
        while end < chars.length() && chars[end] != '}' {
          end = end + 1
        }
        if end == chars.length() {
          fail("\{where_}: `#{` is never closed")
        }
        let path = String::from_array(chars[i + 2:end].to_owned()).trim(
          chars=" ",
        )
        let parts = path.split(".").map(s => s.to_owned()).collect()
        if !parts.iter().all(is_name) {
          fail("\{where_}: `#{\{path}}` is not a parameter")
        }
        if !names.contains(parts[0]) {
          fail("\{where_}: `#{\{path}}` names no parameter of this function")
        }
        paths.push(path.to_owned())
        out.write_string(placeholder(dialect, paths.length()))
        i = end + 1
      }
      ('$', Some('{')) =>
        fail("\{where_}: there is no `${...}`: a value is bound with `#{...}`")
      ('?', _) | ('$', Some('0'..<='9')) =>
        fail(
          "\{where_}: write a bound value as `#{name}`, not as a placeholder",
        )
      _ => {
        out.write_char(c)
        i = i + 1
      }
    }
  }
  (out.to_string(), paths)
}

///|
/// The names a `SELECT` gives its columns, `None` when they cannot be told from
/// the text: `*`, or no `FROM` at the top level.
fn selected(text : String) -> Array[String]? {
  let lower = text.to_lower()
  guard lower.trim(chars=" \n").has_prefix("select") else { return None }
  let chars = lower.to_array()
  let original = text.to_array()
  let start = lower.find("select").unwrap() + "select".length()
  let items : Array[String] = []
  let mut depth = 0
  let mut from = start
  let mut i = start
  let word_at = (at : Int32) => {
    at + 6 <= chars.length() &&
    chars[at:at + 6].iter().collect() == [' ', 'f', 'r', 'o', 'm', ' ']
  }
  let take = (a : Int32, b : Int32) => {
    items.push(String::from_array(original[a:b].to_owned()))
  }
  while i < chars.length() {
    match chars[i] {
      '(' => depth = depth + 1
      ')' => depth = depth - 1
      ',' if depth == 0 => {
        take(from, i)
        from = i + 1
      }
      _ =>
        if depth == 0 && word_at(i) {
          take(from, i)
          return items.map(column_name) |> all_named
        }
    }
    i = i + 1
  }
  None
}

///|
fn all_named(names : Array[String?]) -> Array[String]? {
  let out = []
  for name in names {
    guard name is Some(n) else { return None }
    out.push(n)
  }
  Some(out)
}

///|
/// What one item of a select list is called: its alias, or its last word.
fn column_name(item : String) -> String? {
  let words = item.trim(chars=" \n").split(" ").map(s => s.to_owned()).collect()
  let last = words.filter(w => !w.is_empty()).last().unwrap_or("")
  let name = last
    .rev_find(".")
    .map(at => last[at + 1:].to_owned())
    .unwrap_or(last)
  if is_name(name) {
    Some(name)
  } else {
    None
  }
}

///|
/// The type inside `head[...]`.
fn inside(ty : String, head : String) -> String? {
  if ty.has_prefix(head) && ty.has_suffix("]") {
    Some(
      ty
      .view(start_offset=head.length(), end_offset=ty.length() - 1)
      .trim(chars=" ")
      .to_owned(),
    )
  } else {
    None
  }
}

///|
/// The type inside `T?`.
fn optional_of(ty : String) -> String? {
  if ty.has_suffix("?") {
    Some(ty.view(end_offset=ty.length() - 1).trim(chars=" ").to_owned())
  } else {
    inside(ty, "Option[")
  }
}

///|
/// Whether a value of `ty` reads straight from one column.
fn is_scalar(ty : String) -> Bool {
  ty
  is ("Bool"
  | "Int"
  | "Int32"
  | "Int64"
  | "UInt"
  | "UInt64"
  | "Double"
  | "Float"
  | "String"
  | "Bytes")
}
