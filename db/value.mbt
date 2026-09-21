// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A single dialect-neutral database value — the unit of everything that crosses
/// the driver boundary in either direction. Bound parameters travel *in* as
/// `Value`s (never spliced into the SQL string, so binding is injection-safe by
/// construction) and result columns come *back* as `Value`s.
///
/// This is the moondb analogue of Go's `driver.Value` and Python DB-API's input
/// type objects: a small, closed sum every backend can map onto its own wire
/// types. Drivers are expected to normalise their column types down to these
/// seven cases; a query layer built on moondb reads them back through [`Row`]'s
/// typed accessors.
///
/// * `Null`   — SQL `NULL` / a missing value.
/// * `Bool`   — a boolean; backends without a native boolean map `0`/`1`.
/// * `Int`    — a 32-bit signed integer.
/// * `Int64`  — a 64-bit signed integer (rowids, `BIGINT`, counters).
/// * `Double` — an IEEE-754 double (`REAL` / `FLOAT8`).
/// * `Text`   — a UTF-8 string (`TEXT` / `VARCHAR`); dates and times ride here as
///   ISO-8601 text until a dedicated temporal case lands (see the README roadmap).
/// * `Blob`   — an opaque byte string (`BLOB` / `BYTEA`).
pub(all) enum Value {
  Null
  Bool(Bool)
  Int(Int)
  Int64(Int64)
  Double(Double)
  Text(String)
  Blob(Bytes)
} derive(Eq)

///|
/// The name of a value's variant (`"Null"`, `"Int"`, `"Blob"`, …). Used to build
/// legible [`DbError::TypeError`] messages when a typed accessor is asked for the
/// wrong shape.
pub fn Value::kind(self : Value) -> String {
  match self {
    Null => "Null"
    Bool(_) => "Bool"
    Int(_) => "Int"
    Int64(_) => "Int64"
    Double(_) => "Double"
    Text(_) => "Text"
    Blob(_) => "Blob"
  }
}

///|
/// Whether this value is SQL `NULL`.
pub fn Value::is_null(self : Value) -> Bool {
  self is Null
}

///|
/// Render a `Value` for logs and test output. Scalars print their payload; `Text`
/// is quoted; `Blob` shows its length rather than raw bytes.
pub impl Show for Value with fn output(self : Value, logger : &Logger) -> Unit {
  match self {
    Null => logger.write_string("Null")
    Bool(b) => logger.write_string("Bool(" + b.to_string() + ")")
    Int(v) => logger.write_string("Int(" + v.to_string() + ")")
    Int64(v) => logger.write_string("Int64(" + v.to_string() + ")")
    Double(v) => logger.write_string("Double(" + v.to_string() + ")")
    Text(v) => {
      logger.write_string("Text(\"")
      logger.write_string(v)
      logger.write_string("\")")
    }
    Blob(v) => logger.write_string("Blob(" + v.length().to_string() + " bytes)")
  }
}

///|
pub extend Value with Eq::{not_equal, equal}

///|
pub extend Value with Show::{to_string, output}
