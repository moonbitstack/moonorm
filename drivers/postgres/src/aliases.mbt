// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The dialect-neutral value type this driver binds and decodes. Aliased so the
/// wire code reads `Value` rather than `@moondb.Value` throughout; the enum
/// constructors (`Int`, `Text`, …) are still spelled `@moondb.Int` where a
/// value is built.
pub type Value = @moondb.Value

///|
/// One decoded result row (column names + values), aliased from moondb.
pub type Row = @moondb.Row

///|
/// The outcome of a non-row statement, aliased from moondb.
pub type ExecResult = @moondb.ExecResult

///|
/// The single database error type every fallible operation raises, aliased from
/// moondb so driver signatures read `raise DbError`.
pub type DbError = @moondb.DbError
