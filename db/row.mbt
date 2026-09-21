// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// One row of a result set: the column names in projection order alongside the
/// decoded [`Value`] for each. `columns` and `values` are the same length and are
/// index-aligned — `columns[i]` names `values[i]`.
///
/// This is the shape drivers hand back from [`Driver::query`] and the shape a
/// query layer decodes. Read cells either positionally ([`get`]/[`int`]/…) or by
/// column name ([`by_name`]/[`int_by`]/…). The typed accessors *raise* on a type
/// or lookup mismatch rather than returning a sentinel, so a decode bug surfaces
/// as a `DbError` at the call site instead of silently reading a zero value.
pub(all) struct Row {
  columns : Array[String]
  values : Array[Value]
}

///|
/// The number of columns in the row.
pub fn Row::width(self : Row) -> Int {
  self.values.length()
}

///|
/// The raw [`Value`] at column `idx` (0-based, projection order). Raises
/// `QueryError` if `idx` is out of range.
pub fn Row::get(self : Row, idx : Int) -> Value raise DbError {
  if idx < 0 || idx >= self.values.length() {
    raise QueryError(
      "column index " +
      idx.to_string() +
      " out of range (row has " +
      self.values.length().to_string() +
      " columns)",
    )
  }
  self.values[idx]
}

///|
/// The [`Value`] of the column named `name`, or `None` if the row has no such
/// column. Names match exactly as the driver reported them (case-sensitive).
pub fn Row::by_name(self : Row, name : String) -> Value? {
  for i in 0..<self.columns.length() {
    if self.columns[i] == name {
      return Some(self.values[i])
    }
  }
  None
}

///|
/// Resolve a column `name` to its index, raising `QueryError` if absent. The
/// positional accessors are the primitives; the `_by`-name accessors resolve
/// through this.
pub fn Row::index_of(self : Row, name : String) -> Int raise DbError {
  for i in 0..<self.columns.length() {
    if self.columns[i] == name {
      return i
    }
  }
  raise QueryError("no such column: " + name)
}

///|
/// Whether column `idx` is SQL `NULL`. Raises `QueryError` if `idx` is out of
/// range. Call this before a typed accessor when a column is nullable, since the
/// typed accessors treat `NULL` as a type mismatch.
pub fn Row::is_null(self : Row, idx : Int) -> Bool raise DbError {
  self.get(idx).is_null()
}

///|
/// Whether the column named `name` is SQL `NULL`. Raises `QueryError` if the
/// column is absent.
pub fn Row::is_null_by(self : Row, name : String) -> Bool raise DbError {
  self.get(self.index_of(name)).is_null()
}

// --- positional typed accessors ------------------------------------------------
//
// Each reads column `idx` as a specific MoonBit type, raising `TypeError` when the
// stored value cannot be read that way (including `Null` — use `is_null` first for
// nullable columns) and `QueryError` when `idx` is out of range. Widening between
// integer types and from integer to double is allowed and lossless; `int` narrows
// an `Int64` and is documented as such.

///|
/// Read column `idx` as a `Bool`. Raises `TypeError` unless the cell is `Bool`.
pub fn Row::bool(self : Row, idx : Int) -> Bool raise DbError {
  match self.get(idx) {
    Bool(v) => v
    other =>
      raise TypeError(
        "column " + idx.to_string() + " is " + other.kind() + ", not Bool",
      )
  }
}

///|
/// Read column `idx` as an `Int`, narrowing an `Int64` to its low 32 bits. Raises
/// `TypeError` unless the cell is `Int` or `Int64`.
pub fn Row::int(self : Row, idx : Int) -> Int raise DbError {
  match self.get(idx) {
    Int(v) => v
    Int64(v) => v.to_int()
    other =>
      raise TypeError(
        "column " + idx.to_string() + " is " + other.kind() + ", not Int",
      )
  }
}

///|
/// Read column `idx` as an `Int64`, widening an `Int`. Raises `TypeError` unless
/// the cell is `Int` or `Int64`.
pub fn Row::int64(self : Row, idx : Int) -> Int64 raise DbError {
  match self.get(idx) {
    Int64(v) => v
    Int(v) => v.to_int64()
    other =>
      raise TypeError(
        "column " + idx.to_string() + " is " + other.kind() + ", not Int64",
      )
  }
}

///|
/// Read column `idx` as a `Double`, widening an integer. Raises `TypeError` unless
/// the cell is `Double`, `Int`, or `Int64`.
pub fn Row::double(self : Row, idx : Int) -> Double raise DbError {
  match self.get(idx) {
    Double(v) => v
    Int(v) => v.to_double()
    Int64(v) => v.to_double()
    other =>
      raise TypeError(
        "column " + idx.to_string() + " is " + other.kind() + ", not Double",
      )
  }
}

///|
/// Read column `idx` as text. Raises `TypeError` unless the cell is `Text`.
pub fn Row::text(self : Row, idx : Int) -> String raise DbError {
  match self.get(idx) {
    Text(v) => v
    other =>
      raise TypeError(
        "column " + idx.to_string() + " is " + other.kind() + ", not Text",
      )
  }
}

///|
/// Read column `idx` as an opaque blob. Raises `TypeError` unless the cell is
/// `Blob`.
pub fn Row::blob(self : Row, idx : Int) -> Bytes raise DbError {
  match self.get(idx) {
    Blob(v) => v
    other =>
      raise TypeError(
        "column " + idx.to_string() + " is " + other.kind() + ", not Blob",
      )
  }
}

// --- by-name typed accessors ---------------------------------------------------
//
// Convenience wrappers that resolve a column name through `index_of` (raising
// `QueryError` if absent) and then defer to the positional accessor.

///|
/// Read the column named `name` as a `Bool`.
pub fn Row::bool_by(self : Row, name : String) -> Bool raise DbError {
  self.bool(self.index_of(name))
}

///|
/// Read the column named `name` as an `Int`.
pub fn Row::int_by(self : Row, name : String) -> Int raise DbError {
  self.int(self.index_of(name))
}

///|
/// Read the column named `name` as an `Int64`.
pub fn Row::int64_by(self : Row, name : String) -> Int64 raise DbError {
  self.int64(self.index_of(name))
}

///|
/// Read the column named `name` as a `Double`.
pub fn Row::double_by(self : Row, name : String) -> Double raise DbError {
  self.double(self.index_of(name))
}

///|
/// Read the column named `name` as text.
pub fn Row::text_by(self : Row, name : String) -> String raise DbError {
  self.text(self.index_of(name))
}

///|
/// Read the column named `name` as an opaque blob.
pub fn Row::blob_by(self : Row, name : String) -> Bytes raise DbError {
  self.blob(self.index_of(name))
}

///|
/// The outcome of a non-query statement (INSERT/UPDATE/DELETE/DDL): how many rows
/// it changed and the id of the last inserted row.
///
/// `rows_affected` is 64-bit to hold bulk DML counts; `last_insert_id` is the
/// backend's auto-increment / rowid value and is backend-defined (`0` when the
/// statement produced none). This mirrors Go's `sql.Result` (`RowsAffected` /
/// `LastInsertId`) and DB-API's `cursor.rowcount` / `lastrowid`.
pub(all) struct ExecResult {
  rows_affected : Int64
  last_insert_id : Int64
} derive(Eq)

///|
pub extend ExecResult with Eq::{not_equal, equal}
