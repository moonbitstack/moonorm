// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "translate ? to $n in order" {
  assert_eq(
    @moonpostgres.translate_placeholders(
      "SELECT * FROM t WHERE a = ? AND b = ?",
    ),
    "SELECT * FROM t WHERE a = $1 AND b = $2",
  )
  assert_eq(
    @moonpostgres.translate_placeholders("INSERT INTO t VALUES (?, ?, ?)"),
    "INSERT INTO t VALUES ($1, $2, $3)",
  )
}

///|
test "placeholders inside string literals are left alone" {
  assert_eq(
    @moonpostgres.translate_placeholders("SELECT '?' , a WHERE b = ?"),
    "SELECT '?' , a WHERE b = $1",
  )
  // an embedded escaped quote must not end the literal early
  assert_eq(
    @moonpostgres.translate_placeholders("SELECT 'it''s ? ok' , ?"),
    "SELECT 'it''s ? ok' , $1",
  )
}

///|
test "placeholders inside quoted identifiers and comments are left alone" {
  assert_eq(
    @moonpostgres.translate_placeholders("SELECT \"c?l\" WHERE x = ?"),
    "SELECT \"c?l\" WHERE x = $1",
  )
  assert_eq(
    @moonpostgres.translate_placeholders(
      "SELECT a -- what? not a param\nWHERE b = ?",
    ),
    "SELECT a -- what? not a param\nWHERE b = $1",
  )
  assert_eq(
    @moonpostgres.translate_placeholders(
      "SELECT a /* ? nested /* ? */ still */ , ?",
    ),
    "SELECT a /* ? nested /* ? */ still */ , $1",
  )
}

///|
test "dollar-quoted strings are pass-through" {
  assert_eq(
    @moonpostgres.translate_placeholders("SELECT $tag$ a?b $tag$ , ?"),
    "SELECT $tag$ a?b $tag$ , $1",
  )
}

///|
test "double question mark escapes to a literal ?" {
  assert_eq(
    @moonpostgres.translate_placeholders("SELECT a ?? b WHERE c = ?"),
    "SELECT a ? b WHERE c = $1",
  )
}

///|
test "count_placeholders matches the number bound" {
  assert_eq(@moonpostgres.count_placeholders("a=? b=? c=?"), 3)
  assert_eq(@moonpostgres.count_placeholders("no params here"), 0)
  assert_eq(@moonpostgres.count_placeholders("lit '?' and ?? and one ?"), 1)
}

///|
/// A backslash escape inside a string literal does not end it. Missing that, the
/// scanner walked out of the literal early: a `?` in the *data* was renumbered as a
/// placeholder and the statement's real placeholder was left untranslated.
test "a backslash-escaped quote does not end the literal" {
  let sql = "SELECT E'it\\'s here ? yes', ? FROM t"
  assert_eq(
    @moonpostgres.translate_placeholders(sql),
    "SELECT E'it\\'s here ? yes', $1 FROM t",
  )
  assert_eq(@moonpostgres.count_placeholders(sql), 1)
}

///|
/// The parameter count comes from the scan, not from looking for `$n` in the output
/// — an output `$9` may have been copied through from a literal or a comment.
test "count_placeholders ignores dollar-numbers inside literals and comments" {
  assert_eq(
    @moonpostgres.count_placeholders("SELECT 'lit $9 dollars', ? FROM t"),
    1,
  )
  assert_eq(@moonpostgres.count_placeholders("/* $7 */ SELECT ? FROM t"), 1)
  assert_eq(
    @moonpostgres.count_placeholders(
      "SELECT $tag$ has $9 inside $tag$, ? FROM t",
    ),
    1,
  )
}
