///|
/// The bound-value type is moondb's dialect-neutral [`@moondb.Value`], re-exported
/// here so the builder's public surface reads as `Value` (and its constructors —
/// `Int`, `Text`, `Null`, …) stay unqualified) while the actual type is the one every
/// moondb driver speaks. Values are always carried out-of-band as parameters, never
/// interpolated into the SQL string — that is what makes the builder injection-safe.
pub using @moondb {type Value}

///|
/// The SQL dialect a statement renders for. Most of the builder is dialect-neutral
/// — it emits `?` placeholders and standard clauses that every backend accepts —
/// but a few constructs genuinely differ: upsert is `ON CONFLICT ... DO UPDATE` on
/// SQLite and PostgreSQL versus `ON DUPLICATE KEY UPDATE` on MySQL, and `RETURNING`
/// exists on SQLite and PostgreSQL but not MySQL. `build_for` takes a `Dialect` so
/// those render correctly; the no-argument `build` renders the SQLite/PostgreSQL
/// form, which is also what the `?`-placeholder default targets.
pub(all) enum Dialect {
  Sqlite
  Postgres
  Mysql
} derive(Eq)

///|
pub extend Dialect with Eq::{not_equal, equal}

///|
/// Whether `s` is a bare SQL identifier: a letter or `_`, then letters, digits or `_`.
/// Identifiers cannot be bound as parameters, so a name that is interpolated into SQL
/// (a table, a savepoint) is checked with this first; anything else is refused rather
/// than quoted, which keeps the rule the same on every dialect.
pub fn is_ident(s : String) -> Bool {
  if s.length() == 0 {
    return false
  }
  for i = 0; i < s.length(); i = i + 1 {
    let c = s[i].to_int()
    let alpha = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
    let digit = c >= 48 && c <= 57
    if !(alpha || (i > 0 && digit)) {
      return false
    }
  }
  true
}
