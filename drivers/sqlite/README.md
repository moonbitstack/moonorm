<div align="center">

# moonsqlite

**The native SQLite driver for [`moondb`](https://github.com/moonbitstack/moonorm/tree/master/db) — `impl @moondb.Driver`.**

[![Check and Test](https://github.com/moonbitstack/moonorm/actions/workflows/ci.yml/badge.svg)](https://github.com/moonbitstack/moonorm/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)
[![mooncakes](https://img.shields.io/badge/mooncakes-Lfan--ke%2Fmoonsqlite-brightgreen)](https://mooncakes.io/docs/moonbitstack/moonsqlite)

</div>

> Moved on mooncakes from `moonbitstack/moonsqlite` to `moonbitstack/moonsqlite`.

Previously published as `Lfan-ke/moon-sqlite`.

`moonsqlite` implements the [`moondb`](https://github.com/moonbitstack/moonorm/tree/master/db) `Driver`
interface over the **vendored SQLite amalgamation** (`sqlite/sqlite3.c`, public
domain). Any moondb-based query layer — [`moonorm`](https://github.com/moonbitstack/moonorm)'s
`Session`, or a hand-written statement — runs against a real SQLite database through
it, unchanged.

This is the **only C-touching package** in the moondb / moonorm stack. The
amalgamation is isolated here so everything above it stays pure MoonBit; the package
is native-gated (`supported_targets = "native"`) because it links C.

## Quickstart

> The package name is hyphenated, so import it under an alias in `moon.pkg.json`
> — `{"path": "moonbitstack/moonsqlite", "alias": "sqlite"}` — and reach it as `@sqlite`
> (as below). `Value` constructors come from `@moondb` (`moon add moonbitstack/moondb`).

```moonbit
// native target only — this package links the vendored amalgamation.
fn demo() -> Unit raise @moondb.DbError {
  let db = @sqlite.SqliteDriver::open(":memory:")   // implements @moondb.Driver
  db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)", [])
  |> ignore

  // Bound params map to SQLite storage classes — never spliced into the SQL text.
  db.execute("INSERT INTO users (name, age) VALUES (?, ?)", [
    @moondb.Text("alice"), @moondb.Int(30),
  ]) |> ignore

  // Result columns decode back into @moondb.Value by their runtime type.
  let rows = db.query("SELECT name, age FROM users WHERE age > ?", [@moondb.Int(18)])
  let _ = rows[0].text(0)   // "alice"
  let _ = rows[0].int(1)    // 30
  db.close()
}
```

`SqliteDriver` implements the full `@moondb.Driver` contract — `execute`, `query`,
`begin` / `commit` / `rollback`, and `close` — plus an `exec_script` helper that runs
a semicolon-separated DDL block in one call. Every fallible operation raises
`@moondb.DbError`; the backend's own message rides through on `QueryError`.

## Using it with moonorm

```moonbit
let sess = @moonorm.Session::new(@sqlite.SqliteDriver::open("app.db"))
sess.add(@moonorm.insert("users").set("name", @moondb.Text("bob"))) |> ignore
let rows = sess.fetch(@moonorm.select("users").where_("name", "=", @moondb.Text("bob")))
```

The query builder is dialect-neutral and pure; this driver adapts it to SQLite's
wire. Because moonorm and moonsqlite both speak `@moondb`, swapping SQLite for
another backend is a one-line change at `Session::new`.

## Design & boundaries (honest)

- **Isolated C.** The amalgamation and a thin FFI stub (`sqlite/stub.c`) live in
  `sqlite/`, marked `linguist-vendored` so GitHub reports this as a MoonBit project.
  Nothing outside this package touches C.
- **Handles are integers.** Opaque `sqlite3*` / `sqlite3_stmt*` pointers cross the
  FFI as `Int64` (their pointer bits), inert to the GC — the native runtime never
  reference-counts or frees a foreign pointer.
- **Injection-safe to the wire.** Values are bound out-of-band by SQLite
  (`sqlite3_bind_*`), never interpolated into the SQL string. Text, integers,
  doubles, blobs, booleans (as `0`/`1`), and NULL all round-trip.
- **Real, verified execution.** The integration tests open an actual in-memory
  SQLite database and assert on rows read back across CREATE / INSERT / SELECT /
  UPDATE / DELETE, transactions, blob round-trips, and error propagation. They are
  **mutation-verified**: neutering the C bind path turns them red, so "it runs" is
  proven, not claimed.

## License

Apache-2.0. The bundled SQLite amalgamation (`sqlite/sqlite3.c`, `sqlite/sqlite3.h`)
is public domain, vendored here unmodified.
