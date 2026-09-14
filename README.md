<div align="center">

# moonorm

**An ORM / SQL toolkit for MoonBit — `← SQLAlchemy / SQLModel`.**

[![Check and Test](https://github.com/moonbitstack/moonorm/actions/workflows/ci.yml/badge.svg)](https://github.com/moonbitstack/moonorm/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)
[![mooncakes](https://img.shields.io/badge/mooncakes-Lfan--ke%2Fmoonorm-brightgreen)](https://mooncakes.io/docs/moonbitstack/moonorm)

</div>

> Moved on mooncakes from `Lfan-ke/moonorm` to `moonbitstack/moonorm`.

`moonorm` is the MoonBit counterpart to SQLAlchemy: the heart of SQLAlchemy Core — a **parameterized, injection-safe query builder** — plus a model/session execution layer. Values are never spliced into the SQL the builder produces: every bound value becomes a `?` placeholder plus an entry in a params list. How far that reaches depends on the driver — SQLite and Postgres bind out-of-band, while the MySQL driver still renders parameters as escaped literals over the text protocol (see its README), so there the safety rests on the escaper matching the server's `sql_mode` rather than on the wire format.

`moonorm` owns **no driver contract of its own**. It is written entirely against the [`moondb`](https://github.com/moonbitstack/moonorm/tree/master/db) interface — the standard database-access seam for MoonBit — so it is **pure MoonBit with zero C** and compiles on every backend (`wasm` / `wasm-gc` / `js` / `native`). A concrete backend is a separate package you supply: the native SQLite driver lives in [`moonsqlite`](https://github.com/moonbitstack/moonorm/tree/master/drivers/sqlite), and a `Session` drives any `@moondb.Driver` — including the dependency-free `@moondb.MockDriver` for tests.

> **Imports.** Bound-value constructors (`Int`, `Text`, `Null`, …) are moondb's —
> the `Value` type is re-exported by moonorm, but you construct values as `@moondb.Int`
> / `@moondb.Text` (add `moon add moonbitstack/moondb`). The SQLite driver's package name is
> hyphenated, so import it under an alias in `moon.pkg.json`
> (`{"path": "moonbitstack/moonsqlite", "alias": "sqlite"}`) and reach it as `@sqlite`.

## Quickstart

```moonbit
let (sql, params) = @moonorm.select("users")
  .column("id").column("name")
  .eq("age", @moondb.Int(18))
  .where_("name", "LIKE", @moondb.Text("bob%"))
  .order_by("name", @moonorm.Asc)
  .limit(10)
  .build()
// sql    = "SELECT id, name FROM users WHERE age = ? AND name LIKE ? ORDER BY name ASC LIMIT 10"
// params = [Int(18), Text("bob%")]

let (isql, ivals) = @moonorm.insert("users")
  .set("name", @moondb.Text("bob")).set("age", @moondb.Int(30)).build()
// "INSERT INTO users (name, age) VALUES (?, ?)"

@moonorm.update("users").set("age", @moondb.Int(31)).where_("id", "=", @moondb.Int(1)).build()
@moonorm.delete("users").where_("id", "=", @moondb.Int(9)).build()

// JOIN + GROUP BY + HAVING, with aggregates and a Table descriptor:
let orders : @moonorm.Table = { name: "orders", columns: [] }
let (jsql, jparams) = orders.select()
  .raw("users.name").count()
  .join("users", "users.id = orders.user_id")
  .eq("orders.status", @moondb.Text("paid"))
  .group_by("users.name")
  .having("COUNT(*)", ">", @moondb.Int(3))
  .build()
// "SELECT users.name, COUNT(*) FROM orders JOIN users ON users.id = orders.user_id
//  WHERE orders.status = ? GROUP BY users.name HAVING COUNT(*) > ?"
// params = [Text("paid"), Int(3)]
```

## Running against a real database

The builder is only half the story — `moonorm` also **executes**, against any
`@moondb.Driver`. Add the native SQLite driver and a `Session` runs your built
statements against an actual database and hands back typed rows. Every fallible
operation *raises* `@moondb.DbError` (a decode or backend error surfaces at the call
site, never as a silent zero value), so call them inside a function that propagates
that error:

```moonbit
// native target only — moonsqlite links the vendored amalgamation.
fn demo() -> Unit raise @moondb.DbError {
  let sess = @moonorm.Session::new(@sqlite.SqliteDriver::open(":memory:"))
  sess.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)", []) |> ignore

  // INSERT through the builder — values are bound, never spliced.
  sess.add(@moonorm.insert("users").set("name", @moondb.Text("alice")).set("age", @moondb.Int(30)))
  |> ignore

  // SELECT through the builder — real rows come back, typed.
  let rows = sess.fetch(
    @moonorm.select("users").column("name").column("age").where_("age", ">", @moondb.Int(18)),
  )
  let _ = rows[0].text(0)  // "alice"  (raises TypeError if the column isn't Text)
  let _ = rows[0].int(1)   // 30
  sess.close()
}
```

`Session` also has `modify` (UPDATE), `remove` (DELETE), `begin` / `commit` /
`rollback` (delegated to the driver's transaction bracket), nested transactions via
`savepoint` / `rollback_to` / `release` (SQLAlchemy's `begin_nested`), and raw
`execute` / `query`. Everything travels as bound parameters as far as the driver
carries them; see the note above on the MySQL text protocol.

## Models & relationships

A `Model[T]` is the explicit declarative mapping between a table and a MoonBit
record — the typed columns plus the two mapping closures MoonBit cannot synthesise
for want of reflection (`Row -> record`, `record -> bound columns`). From it you get
`CREATE TABLE` DDL, typed inserts, and eager foreign-key loading. Because MoonBit
has no attribute interception, `parent.children` cannot silently fire a SELECT the
way SQLAlchemy's lazy load does; the load is an explicit call — `session.load` /
`session.load_one` — exactly the shape Diesel's preload and GORM's `Preload` take.

The mapping closures read cells through `@moondb.Row`'s typed accessors, which
*raise* on a type or index mismatch — so `from_row` raises too and a decode bug
surfaces at the call site, not as a silent zero. Write them in **arrow form** so the
`raise` effect is inferred:

```moonbit
// A parent model and a child model with a foreign key back to it.
let teams : @moonorm.Model[Team] = @moonorm.Model::new(
  "teams",
  [@moonorm.column("id", @moonorm.IntType, primary_key=true),
   @moonorm.column("name", @moonorm.TextType, nullable=false)],
  (r) => { id: r.int(0), name: r.text(1) },
  (t) => [("id", @moondb.Int(t.id)), ("name", @moondb.Text(t.name))],
)
let heroes : @moonorm.Model[Hero] = @moonorm.Model::new(
  "heroes",
  [@moonorm.column("id", @moonorm.IntType, primary_key=true),
   @moonorm.column("name", @moonorm.TextType, nullable=false),
   @moonorm.column("team_id", @moonorm.IntType, references=Some(("teams", "id")))],
  (r) => { id: r.int(0), name: r.text(1), team_id: r.int(2) },
  (h) => [("id", @moondb.Int(h.id)), ("name", @moondb.Text(h.name)),
          ("team_id", @moondb.Int(h.team_id))],
)

sess.create_table(teams) |> ignore          // CREATE TABLE teams (id INTEGER PRIMARY KEY, name TEXT NOT NULL)
sess.create_table(heroes) |> ignore
sess.insert_record(teams, { id: 1, name: "avengers" }) |> ignore
sess.insert_record(heroes, { id: 10, name: "iron-man", team_id: 1 }) |> ignore

// 1:N — a team's heroes, eager-loaded as mapped records.
let children = @moonorm.has_many(heroes, "team_id", (t : Team) => @moondb.Int(t.id))
let kids = sess.load({ id: 1, name: "avengers" }, children)   // [Hero{...}, ...]

// N:1 — a hero's team.
let parent = @moonorm.belongs_to(teams, "id", (h : Hero) => @moondb.Int(h.team_id))
let team = sess.load_one({ id: 10, name: "iron-man", team_id: 1 }, parent)  // Some(Team{...})
```

The relationship's match value is bound, never spliced, so eager loading is
injection-safe like every other query.

### Declarative models from a field list

Writing `to_columns` by hand repeats what the columns already say. `Model::from_fields`
takes that other half off you: give it a list of `field`s — each a column plus the
one-line projection that reads it off a record — and it derives the column list, the
`CREATE TABLE` DDL, the `SELECT` projection, and the `INSERT` binding. You still supply
`from_row`, because turning a fetched row back into a `T` needs the record constructor,
and MoonBit — with no reflection — cannot synthesise it; that one closure is the
irreducible core of the mapping. This is exactly the shape `moonctl`'s `model` generator
emits from an `#orm`-annotated struct — a `[field(...)]` array and a `from_row`:

```moonbit
let heroes : @moonorm.Model[Hero] = @moonorm.Model::from_fields(
  "heroes",
  [
    @moonorm.field("id", @moonorm.IntType, (h : Hero) => @moondb.Int(h.id), primary_key=true),
    @moonorm.field("name", @moonorm.TextType, (h : Hero) => @moondb.Text(h.name), nullable=false),
    @moonorm.field("team_id", @moonorm.IntType, (h : Hero) => @moondb.Int(h.team_id),
                   references=Some(("teams", "id"))),
  ],
  (r) => { id: r.int(0), name: r.text(1), team_id: r.int(2) },   // the one closure that stays
)
```

### Batch loading (avoiding N+1)

Calling `load` once per parent is the N+1 trap — one SELECT per row. `load_batch` fetches
the children of *many* parents in a single `WHERE fk IN (…)` round trip and buckets them
back, index-aligned with the sources you passed. `load_one_batch` is the N:1 counterpart.
This is the explicit equivalent of SQLAlchemy's `selectinload`:

```moonbit
let children = @moonorm.has_many(heroes, "team_id", (t : Team) => @moondb.Int(t.id))
let teams : Array[Team] = [{ id: 1, name: "avengers" }, { id: 2, name: "x-men" }]
let grouped = sess.load_batch(teams, children)   // one query; grouped[0] = avengers' heroes, …
```

### Nested transactions & isolation

`begin_nested` opens a SAVEPOINT and hands back a handle that names and depth-tracks it
for you (SQLAlchemy's `Session.begin_nested()`): finish it with `release` to keep the work
or `rollback` to discard it back to the savepoint, both terminal and idempotent. For an
isolation level or a read-only transaction, `begin_with` renders the backend's
`SET TRANSACTION` (or SQLite `PRAGMA`) and orders it correctly around `BEGIN` per dialect:

```moonbit
let sp = sess.begin_nested()          // SAVEPOINT moonorm_sp_1; sess.savepoint_depth() == 1
sess.add(insert_stmt) |> ignore
sp.rollback()                         // undo just this savepoint's work; depth back to 0

sess.begin_with({ isolation: Some(@moonorm.Serializable), read_only: false }, dialect=@moonorm.Postgres)
// BEGIN; SET TRANSACTION ISOLATION LEVEL SERIALIZABLE
```

### Design & boundaries (honest)

- **Explicit, not magic.** SQLAlchemy issues SQL implicitly when you touch a
  mapped attribute; MoonBit has no attribute interception, so every statement is
  issued explicitly via `Session` — the same faithful trade Diesel and GORM make.
- **Pure, zero C.** moonorm is written entirely against the `@moondb` seam, so the
  whole library compiles on **every** backend (`wasm` / `wasm-gc` / `js` /
  `native`) and drags no backend behind it. The C lives in one isolated place —
  [`moonsqlite`](https://github.com/moonbitstack/moonorm/tree/master/drivers/sqlite) — not here. A Postgres
  wire-protocol backend and a JS `node:sqlite` backend are next.
- **Tested against a real driver.** The Session/Model/relationship layer is covered
  on every backend against `@moondb.MockDriver`; real SQL execution is proven end to
  end in moonsqlite's native integration tests, which open an actual SQLite database
  and are mutation-verified (neutering the C bind path turns them red).

## Subqueries, CTEs & optimistic locking

The builder does `WITH` common table expressions and `IN (subquery)` predicates, and
both keep the injection-safety guarantee — a subquery's bound values splice into the
params list in the exact left-to-right order they appear in the SQL text:

```moonbit
let big = @moonorm.select("orders").column("user_id").where_("total", ">", @moondb.Int(100))
let (sql, params) = @moonorm.select("users")
  .column("id").column("name")
  .with_cte("big_spenders", big)
  .where_("active", "=", @moondb.Bool(true))
  .where_in("id", @moonorm.select("big_spenders").column("user_id"))
  .build()
// "WITH big_spenders AS (SELECT user_id FROM orders WHERE total > ?)
//  SELECT id, name FROM users WHERE active = ? AND id IN (SELECT user_id FROM big_spenders)"
// params = [Int(100), Bool(true)]   ← CTE value first, then the WHERE value
```

Optimistic concurrency control mirrors SQLAlchemy's `version_id_col`. Write an UPDATE
that bumps the version and guards on the one you read; `modify_versioned` runs it and
raises `LostUpdate` if no row matched — the update was lost to a concurrent writer:

```moonbit
let stmt = @moonorm.update("account")
  .set("balance", @moondb.Int(50))
  .set("version", @moondb.Int(current + 1))
  .where_("id", "=", @moondb.Int(1))
  .where_("version", "=", @moondb.Int(current))   // the guard
sess.modify_versioned(stmt, what="account") |> ignore   // raises LostUpdate on a stale version
```

## Migrations

Versioned schema migrations, tracked in a `schema_migrations` table — the Alembic /
diesel-migrations counterpart. A `Migration` carries an integer version plus its `up`
and `down` statement lists; a `Migrator` applies pending versions in ascending order,
skips ones already applied (so re-running is a no-op), rolls back to a target version
in descending order, and reports the current version.

```moonbit
let migrations : Array[@moonorm.Migration] = [
  { version: 1, name: "create_users",
    up: ["CREATE TABLE users (id INTEGER PRIMARY KEY)"], down: ["DROP TABLE users"] },
  { version: 2, name: "add_email",
    up: ["ALTER TABLE users ADD COLUMN email TEXT"], down: ["ALTER TABLE users DROP COLUMN email"] },
]
let m = @moonorm.Migrator::new()
m.up(sess, migrations) |> ignore          // applies 1 then 2; returns how many ran
let _ = m.current_version(sess)            // 2
m.down_to(sess, migrations, 1) |> ignore   // rolls back 2, leaving 1
```

## Injection safety

```moonbit
let evil = "'; DROP TABLE users; --"
let (sql, params) = @moonorm.select("users").eq("name", @moondb.Text(evil)).build()
// sql    = "SELECT * FROM users WHERE name = ?"   ← the attack string is NOT in the SQL
// params = [Text("'; DROP TABLE users; --")]      ← it's a bound parameter
```

Verified across all backends (`wasm`, `wasm-gc`, `js`, `native`) in CI, 0 warnings under `--deny-warn`.

## Roadmap (transliterating SQLAlchemy)

`select` / `insert` / `update` / `delete` with WHERE / ORDER BY / LIMIT / OFFSET, inner/left `JOIN`, `GROUP BY` / `HAVING`, aggregate columns (`count()` / `raw()`), `WITH` CTEs, `IN (subquery)` and `IN (values)` predicates, window functions (`OVER (PARTITION BY … ORDER BY …)`), dialect-aware `RETURNING` and upsert (`ON CONFLICT … DO UPDATE` / `ON DUPLICATE KEY UPDATE`), and a `Table` descriptor are all here — and they **execute** against any `@moondb.Driver` via an explicit `Session` (`add` / `fetch` / `modify` / `remove` / `commit` / `rollback`, optimistic-locked updates, isolation-level and read-only transactions via `begin_with`, depth-tracked nested savepoints via `begin_nested`, plus declarative models — hand-built or `from_fields` from `moonctl`-generated metadata — eager-loaded relationships with N+1-avoiding batch loading, and versioned migrations). Connection pooling lives in [`moondb`](https://github.com/moonbitstack/moonorm) as `Pool[D]`: idle reuse, a size ceiling, a `pre_ping` health probe that evicts dead connections on acquire, `max_lifetime` recycling, a non-blocking `try_acquire`, and close-all. The native SQLite backend is [`moonsqlite`](https://github.com/moonbitstack/moonorm/tree/master/drivers/sqlite); Postgres and MySQL/MariaDB backends live in [`moonpostgres`](https://github.com/moonbitstack/moonorm/tree/master/drivers/postgres) and [`moonmysql`](https://github.com/moonbitstack/moonorm/tree/master/drivers/mysql). Still to come: Alembic-style schema-diff migrations reflected from a live database, and multiple-inheritance / polymorphic mapping.

## License

Apache-2.0.
