// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A MoonBit value that binds as a parameter: Go's `driver.Valuer`, Diesel's
/// `ToSql`. Implemented for the type behind each [`Value`] case and for `T?`,
/// where `None` binds `NULL`. A type of the program's own implements it to be
/// stored as one of those cases.
pub(open) trait ToValue {
  fn to_value(Self) -> Value
}

///|
/// A MoonBit value read back from a cell: Go's `sql.Scanner`, Diesel's `FromSql`.
/// The conversions are the ones [`Row`]'s typed accessors make. A refusal is a
/// `TypeError` whose message reads after "column N is", such as `"Text, not Int"`.
pub(open) trait FromValue {
  fn from_value(Value) -> Self raise DbError
}

///|
fn refuse(got : Value, want : String) -> DbError {
  TypeError(got.kind() + ", not " + want)
}

///|
pub impl ToValue for Value with fn to_value(self) {
  self
}

///|
pub impl FromValue for Value with fn from_value(v) {
  v
}

///|
pub extend Value with ToValue::{to_value}

///|
pub extend Value with FromValue::{from_value}

///|
pub impl ToValue for Bool with fn to_value(self) {
  Bool(self)
}

///|
pub impl FromValue for Bool with fn from_value(v) {
  match v {
    Bool(b) => b
    other => raise refuse(other, "Bool")
  }
}

///|
pub impl ToValue for Int32 with fn to_value(self) {
  Int(self)
}

///|
/// Narrows an `Int64` to its low 32 bits, as [`Row::int`] does.
pub impl FromValue for Int32 with fn from_value(v) {
  match v {
    Int(n) => n
    Int64(n) => n.to_int()
    other => raise refuse(other, "Int")
  }
}

///|
pub impl ToValue for Int64 with fn to_value(self) {
  Int64(self)
}

///|
pub impl FromValue for Int64 with fn from_value(v) {
  match v {
    Int64(n) => n
    Int(n) => n.to_int64()
    other => raise refuse(other, "Int64")
  }
}

///|
pub impl ToValue for Double with fn to_value(self) {
  Double(self)
}

///|
pub impl FromValue for Double with fn from_value(v) {
  match v {
    Double(d) => d
    Int(n) => n.to_double()
    Int64(n) => n.to_double()
    other => raise refuse(other, "Double")
  }
}

///|
pub impl ToValue for String with fn to_value(self) {
  Text(self)
}

///|
pub impl FromValue for String with fn from_value(v) {
  match v {
    Text(s) => s
    other => raise refuse(other, "Text")
  }
}

///|
pub impl ToValue for Bytes with fn to_value(self) {
  Blob(self)
}

///|
pub impl FromValue for Bytes with fn from_value(v) {
  match v {
    Blob(b) => b
    other => raise refuse(other, "Blob")
  }
}

///|
pub impl[T : ToValue] ToValue for T? with fn to_value(self) {
  match self {
    Some(x) => x.to_value()
    None => Null
  }
}

///|
pub impl[T : FromValue] FromValue for T? with fn from_value(v) {
  match v {
    Null => None
    v => Some(T::from_value(v))
  }
}
