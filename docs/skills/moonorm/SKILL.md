---
name: moonorm
description: Build SQL from MoonBit values and map rows back into records — a typed schema, a parameterised builder, a unit-of-work session (synchronous or asynchronous), event hooks, and revision migrations that render for SQLite, PostgreSQL and MySQL. Reach for it when a MoonBit program has to talk to a relational database.
---

# moonorm

An ORM and SQL toolkit. Every value is bound, never spliced into the statement; the
schema is declared in code, since MoonBit cannot reflect over a record.

## Install and import

```
moon add moonbitstack/moonorm
moon add moonbitstack/moondb
```

`moonbitstack/moonorm` re-exports the types; constructors and enum variants have to be
named by the package that declares them, so `moon.pkg` usually imports the subpackages
too:

```
import {
  "moonbitstack/moonorm",
  "moonbitstack/moonorm/schema",
  "moonbitstack/moonorm/session",
  "moonbitstack/moondb",
}
```

A backend is a separate package: `moonbitstack/moonsqlite`, `moonbitstack/moonpostgres`,
`moonbitstack/moonmysql`. `@moondb.MockDriver` needs no backend at all.

## Declare a table and use it

```moonbit
struct Hero {
  id : Int32
  name : String
}

fn hero_row(r : @moondb.Row) -> Hero raise @moondb.DbError {
  { id: r.int(0), name: r.text(1) }
}

fn hero_model() -> @moonorm.Model[Hero] {
  let fields : Array[@moonorm.Field[Hero]] = [
    @moonorm.field("id", @schema.IntType, h => h.id, primary_key=true),
    @moonorm.field("name", @schema.TextType, h => h.name, nullable=false),
  ]
  @moonorm.Model::from_fields("heroes", fields, hero_row)
}
```

`Model::select` projects the declared columns, `Session::fetch_as` maps them back,
`Session::add_record` queues a row and `Session::commit` writes it:

```moonbit
fn save(sess : @session.Session) -> Unit raise @moondb.DbError {
  let model = hero_model()
  sess.create_table(model, if_not_exists=true) |> ignore
  sess.add_record(model, { id: 1, name: "Ada" })
  sess.commit()
  let heroes = sess.all(model)
  ignore(heroes)
}
```

## Version the schema

A revision names its parents, so a history can branch and merge. A change is a list of
operation values, so one revision renders for every dialect.

```moonbit
fn revisions() -> Array[@moonorm.Revision] {
  [
    @moonorm.Revision::new(
      id="0001",
      name="create heroes",
      up=[@moonorm.create_table("heroes", [
        @moonorm.column("id", @schema.IntType, primary_key=true),
        @moonorm.column("name", @schema.VarcharType(255), nullable=false),
      ])],
      down=[@moonorm.drop_table("heroes")],
    ),
  ]
}

fn migrate(sess : @session.Session) -> Array[String] raise @moondb.DbError {
  @moonorm.Migrator::new().upgrade(sess, revisions())
}
```

`upgrade_sql` returns exactly the statements `upgrade` runs, which is the offline mode
and what an async driver (PostgreSQL) executes; `autogenerate_changes` returns the
operations that close the gap between a declared `TableSpec` set and a reflected one,
each with its inverse.

## Reach a networked backend

PostgreSQL and MySQL only implement `@moondb.AsyncDriver`, so they are driven through
`AsyncSession`, which has the same methods as `Session`, awaited:

```moonbit
async fn count(sess : @session.AsyncSession) -> Int32 raise @moondb.DbError {
  let rows = sess.all(hero_model())
  rows.length()
}
```

One session is one connection and runs one statement at a time. For concurrency, take
connections from a pool — `AsyncSession::with_pool` returns the connection whatever the
work does:

```moonbit
async fn[D : @moondb.AsyncDriver] each(
  pool : @apool.AsyncPool[D],
) -> Unit raise @moondb.DbError {
  @session.AsyncSession::with_pool(pool, sess => {
    sess.query("SELECT 1", []) |> ignore
  })
}
```

## Rules that catch people out

- Values travel as `?` placeholders plus a params list. Never build SQL by string
  concatenation; a table or column name that has to be interpolated is checked with
  `is_ident` by everything in this library.
- `@moonorm.Postgres`, `@moonorm.IntType` and `@moonorm.BeforeInsert` do not resolve:
  `pub using` re-exports types, not constructors. Write `@query.Postgres`,
  `@schema.IntType`, `@session.BeforeInsert`, or let an expected type pick the variant.
- A hybrid's expression writes `{t}` where the table qualifier belongs. A query whose
  `FROM` is a derived table has no name to fill in, and asking for one raises.
- SQLite cannot change a column's type or nullability in place, add a foreign key or
  drop one: `alter_column` and the foreign-key operations raise there, and
  `rebuild_table` is the four-step swap that does work. PostgreSQL and MySQL alter in
  place and refuse `rebuild_table`.
- MySQL cannot index a bare `TEXT` column — declare `VarcharType(n)` for an indexed
  string — and drops an index with `DROP INDEX name ON table`, so `drop_index` needs
  the table on that dialect.
- A joined-table subclass is one model: reads join the parent, writes emit two
  statements in the order the foreign key requires. Do not queue the halves yourself.
- A savepoint rollback takes the session with it: writes queued since the savepoint
  left the queues and the identity map went back to what it held then. Do not re-flush
  the same records afterwards, and re-`get` anything a rollback may have undone.
- A SQLite read-only transaction sets `PRAGMA query_only` on the connection; `commit`
  and `rollback` clear it. Do not issue your own `PRAGMA query_only = 0` around it.
- `AsyncSession::close` is the only method that does not raise — it is best-effort, as
  closing a cursor is.
