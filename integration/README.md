# moonorm end-to-end integration

> The module is named `moonbitstack/moone2e`. It is not published, so it has no
> mooncakes entry; the name follows the family rule of `moon` plus a short root.

This module isn't published. It exists so CI can prove the published ORM and the
published SQLite driver work together against a real database, not a mock.

It pins the released packages by version — `moonbitstack/moonorm`, `moonbitstack/moonsqlite`,
`moonbitstack/moondb` — opens a SQLite file, and runs one test that walks the whole stack:

- versioned migrations up (create team, create hero, add an index), then down to zero
- a `Session` doing CRUD through declared `Model`s
- a `WITH` CTE feeding an `IN` subquery
- an optimistic-locked update that succeeds once and then catches a stale write as `LostUpdate`

Because `moonsqlite` links the vendored SQLite amalgamation, the package is
native-only.

```
moon test --target native
```
