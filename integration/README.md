# moonorm end-to-end integration

This module isn't published. It exists so CI can prove the published ORM and the
published SQLite driver work together against a real database, not a mock.

It pins the released packages by version — `Lfan-ke/moonorm`, `Lfan-ke/moonsqlite`,
`Lfan-ke/moondb` — opens a SQLite file, and runs one test that walks the whole stack:

- versioned migrations up (create team, create hero, add an index), then down to zero
- a `Session` doing CRUD through declared `Model`s
- a `WITH` CTE feeding an `IN` subquery
- an optimistic-locked update that succeeds once and then catches a stale write as `LostUpdate`

Because `moonsqlite` links the vendored SQLite amalgamation, the package is
native-only.

```
moon test --target native
```
