///|
/// The type inside `T?` or `Option[T]`, or `None` when `ty` is not optional.
fn inner_option(ty : String) -> String? {
  let ty = ty.trim(chars=" ")
  if ty.has_suffix("?") {
    Some(ty.view(end_offset=ty.length() - 1).trim(chars=" ").to_owned())
  } else if ty.has_prefix("Option[") && ty.has_suffix("]") {
    Some(
      ty
      .view(start_offset="Option[".length(), end_offset=ty.length() - 1)
      .trim(chars=" ")
      .to_owned(),
    )
  } else {
    None
  }
}

///|
/// The column type a field of type `ty` takes when `kind=` is not given, as the
/// `ColumnType` constructor. The types are the ones behind each `Value` case.
fn column_of(ty : String) -> String? {
  match ty {
    "Int" | "Int32" => Some("IntType")
    "Int64" => Some("BigIntType")
    "Double" => Some("RealType")
    "String" => Some("TextType")
    "Bytes" => Some("BlobType")
    "Bool" => Some("BoolType")
    _ => None
  }
}

///|
/// The `ColumnType` constructor a `kind=` names: the SQL spelling, lower case.
fn column_named(name : String) -> String? {
  let name = name.trim(chars=" ").to_lower()
  match name {
    "int" | "integer" => Some("IntType")
    "bigint" => Some("BigIntType")
    "text" => Some("TextType")
    "real" => Some("RealType")
    "blob" => Some("BlobType")
    "bool" | "boolean" => Some("BoolType")
    "numeric" => Some("NumericType")
    "datetime" => Some("DateTimeType")
    "date" => Some("DateType")
    "time" => Some("TimeType")
    "uuid" => Some("UuidType")
    "json" => Some("JsonType")
    _ => {
      guard name.has_prefix("varchar(") && name.has_suffix(")") else {
        return None
      }
      let n = name.view(
        start_offset="varchar(".length(),
        end_offset=name.length() - 1,
      )
      let n = @string.parse_int(n) catch { _ => return None }
      if n > 0 {
        Some("VarcharType(\{n})")
      } else {
        None
      }
    }
  }
}

///|
/// `HeroTeam` as `hero_team`, `HTTPLog` as `http_log`.
fn snake(name : String) -> String {
  let out = StringBuilder()
  let chars = name.to_array()
  for i, c in chars {
    if c.is_ascii_uppercase() {
      let prev = if i > 0 { Some(chars[i - 1]) } else { None }
      let next = chars.get(i + 1)
      let boundary = match prev {
        Some(p) =>
          p.is_ascii_lowercase() ||
          p.is_ascii_digit() ||
          (p.is_ascii_uppercase() && next is Some(n) && n.is_ascii_lowercase())
        None => false
      }
      if boundary {
        out.write_char('_')
      }
      out.write_char(c.to_ascii_lowercase())
    } else {
      out.write_char(c)
    }
  }
  out.to_string()
}
