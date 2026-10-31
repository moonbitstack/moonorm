<div align="center">

# moonorm

[Site](https://moonbitstack.github.io/moonorm/) ·
[Guide](https://moonbitstack.github.io/moonorm/guide.html) ·
[API](https://moonbitstack.github.io/moonorm/api.html) ·
[mooncakes](https://mooncakes.io/docs/moonbitstack/moonorm)

**An ORM and SQL toolkit for MoonBit: a typed schema, three dialects, and values that are always bound.**

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)
[![mooncakes](https://img.shields.io/badge/mooncakes-moonbitstack%2Fmoonorm-brightgreen)](https://mooncakes.io/docs/moonbitstack/moonorm)

</div>

`moonorm` builds SQL from MoonBit values, and maps rows back into MoonBit
records. Nothing is spliced into the statement: every value becomes a `?`
placeholder plus an entry in a params list, so a string carrying SQL is data, not
syntax. How far that reaches depends on the driver — SQLite and PostgreSQL bind
out of band, while the MySQL driver still renders parameters as escaped literals
over the text protocol (see its README), so there the safety rests on the escaper
matching the server's `sql_mode`.

`moonorm` owns **no driver contract of its own**. It is written entirely against
the [`moondb`](https://moonbitstack.github.io/moondb/) interface, so it is pure
MoonBit with zero C and compiles on every backend (`wasm` / `wasm-gc` / `js` /
`native`). A backend is a separate package you supply: the native SQLite driver
lives in [`moonsqlite`](https://github.com/moonbitstack/moondb/tree/master/drivers/sqlite), the PostgreSQL and MySQL/MariaDB
drivers in [`moonpostgres`](https://github.com/moonbitstack/moondb/tree/master/drivers/postgres) and [`moonmysql`](https://github.com/moonbitstack/moondb/tree/master/drivers/mysql),
and a `Session` drives any `@moondb.Driver` — including the dependency-free
`@moondb.MockDriver`.

> **Imports.** Bound-value constructors (`Int`, `Text`, `Null`, …) are moondb's:
> the `Value` type is re-exported by moonorm, but you construct values as
> `@moondb.Int` / `@moondb.Text` (add `moon add moonbitstack/moondb`). A model
> field needs none of them: `field` binds the attribute itself, and `Row::read`
> reads a cell as the field's type. The examples that touch a real database
> import the SQLite driver under a short alias, `"moonbitstack/moonsqlite" @sqlite`
> in `moon.pkg`.

## Packages

Each layer is its own subpackage: the builder, the schema, the session, and
migrations. The root re-exports all of them, so `@moonorm.select` and
`@moonorm.Session` work.

|  Package  | What it holds | Depends on |
|:--:|:--|:--|
| `moonorm/query` | dialects, predicates, `select` / `insert` / `update` / `delete`, `Table`, `is_ident` | moondb's `Value` |
| `moonorm/schema` | `ColumnType`, `Column`, `Field`, `Model`, `Relation`, `ManyToMany` | `query`, moondb |
| `moonorm/session` | `Session`, row streams, transactions and savepoints, the unit of work, pooled sessions | `schema`, `query`, moondb |
| `moonorm/migrate` | `Migration`, `Migrator`, `ColumnDiff`, schema reflection and diffing | `session`, `schema`, `query` |
| `moonorm/cmd/orm` | the generator behind `#orm.table`, `#orm.column`, `#orm.skip`, `#orm.index`, `#orm.has_many` and `#orm.belongs_to` | moonast |

A program that only renders SQL imports `query` and nothing else.

**Constructors are written without the package.** `pub using` re-exports types but
not their constructors, so `@moonorm.Postgres` does not resolve. Write the bare
constructor and let the expected type pick it: `stmt.build_for(Postgres)`. Where
nothing gives the type, annotate or name the subpackage:
`let levels : Array[@moonorm.IsolationLevel] = [ReadCommitted, Serializable]`, or
`catch { @session.LostUpdate(msg) => ... }`.

## Quickstart

```moonbit
pub fn quickstart() -> Unit {
  let (sql, params) = @moonorm.select("users")
    .column("id")
    .column("name")
    .eq("age", @moondb.Int(18))
    .where_("name", "LIKE", @moondb.Text("bob%"))
    .order_by("name", Asc)
    .limit(10)
    .build()
  // SELECT id, name FROM users WHERE age = ? AND name LIKE ? ORDER BY name ASC LIMIT 10
  // params: [Int(18), Text("bob%")]
  ignore((sql, params))
}

pub fn joins() -> Unit {
  let orders : @moonorm.Table = { name: "orders", columns: [] }
  let (sql, params) = orders
    .select()
    .raw("users.name")
    .count()
    .join("users", "users.id = orders.user_id")
    .eq("orders.status", @moondb.Text("paid"))
    .group_by("users.name")
    .having("COUNT(*)", ">", @moondb.Int(3))
    .build()
  // SELECT users.name, COUNT(*) FROM orders JOIN users ON users.id = orders.user_id
  //   WHERE orders.status = ? GROUP BY users.name HAVING COUNT(*) > ?
  // params: [Text("paid"), Int(3)]
  ignore((sql, params))
}
```

`insert`, `update` and `delete` follow the same shape: `@moonorm.insert("users")
.set("name", ...)` , `.where_(...)`, then `.build()` for the statement text and
its params.

## Running against a real database

The builder is half of it — `moonorm` also **executes**, against any
`@moondb.Driver`. Add a driver and a `Session` runs the statements you built and
hands back typed rows. Every fallible operation raises `@moondb.DbError`, so a
decode or backend error surfaces at the call site instead of as a silent zero:

```moonbit
// native target only — moonsqlite links the vendored amalgamation.
pub fn demo() -> Unit raise @moondb.DbError {
  let sess = @moonorm.Session::new(@sqlite.SqliteDriver::open(":memory:"))
  sess.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)", [])
  |> ignore

  // INSERT through the builder — values are bound, never spliced.
  sess.add(
    @moonorm.insert("users").set("name", @moondb.Text("alice")).set("age", @moondb.Int(30)),
  )
  |> ignore

  // SELECT through the builder — real rows come back, typed.
  let rows = sess.fetch(
    @moonorm.select("users").column("name").column("age").where_("age", ">", @moondb.Int(18)),
  )
  let _ = rows[0].text(0) // "alice"  (raises TypeError if the column is not Text)
  let _ = rows[0].int(1) // 30
  sess.close()
}
```

`Session` also has `modify` (UPDATE), `remove` (DELETE), `begin` / `commit` /
`rollback` (delegated to the driver's transaction bracket), nested transactions
via `savepoint` / `rollback_to` / `release`, and raw `execute` / `query`.

## Models & relationships

A `Model[T]` is the explicit mapping between a table and a MoonBit record: the
typed columns plus the two mapping closures MoonBit cannot synthesise without
reflection (`Row -> record`, `record -> bound columns`). From it you get
`CREATE TABLE` DDL, typed inserts, and eager foreign-key loading. Because there
is no attribute interception, `parent.children` cannot fire a SELECT behind your
back; the load is an explicit call — `session.load` / `session.load_one`.

The mapping closures read cells through `@moondb.Row`'s typed accessors, which
*raise* on a type or index mismatch — so `from_row` raises too, and a decode bug
surfaces at the call site. Write them in **arrow form** so the `raise` effect is
inferred:

```moonbit
pub struct Team {
  id : Int
  name : String
}

pub struct Hero {
  id : Int
  name : String
  team_id : Int
}

pub fn models() -> (Array[@moonorm.Model[Team]], Array[@moonorm.Model[Hero]]) {
  let teams : @moonorm.Model[Team] = @moonorm.Model::new(
    "teams",
    [
      @moonorm.column("id", IntType, primary_key=true),
      @moonorm.column("name", TextType, nullable=false),
    ],
    (r) => { { id: r.int(0), name: r.text(1) } },
    (t) => [("id", @moondb.Int(t.id)), ("name", @moondb.Text(t.name))],
  )
  let heroes : @moonorm.Model[Hero] = @moonorm.Model::new(
    "heroes",
    [
      @moonorm.column("id", IntType, primary_key=true),
      @moonorm.column("name", TextType, nullable=false),
      @moonorm.column("team_id", IntType, references=("teams", "id")),
    ],
    (r) => { { id: r.int(0), name: r.text(1), team_id: r.int(2) } },
    (h) => [
      ("id", @moondb.Int(h.id)),
      ("name", @moondb.Text(h.name)),
      ("team_id", @moondb.Int(h.team_id)),
    ],
  )
  ([teams], [heroes])
}
```

Against a session those models give you the whole cycle:

```moonbit
pub struct Team {
  id : Int
  name : String
}

pub struct Hero {
  id : Int
  name : String
  team_id : Int
}

pub fn mapping(sess : @moonorm.Session, teams : @moonorm.Model[Team], heroes : @moonorm.Model[Hero]) -> Unit raise @moondb.DbError {
  sess.create_table(teams) |> ignore // CREATE TABLE teams (id INTEGER PRIMARY KEY, name TEXT NOT NULL)
  sess.create_table(heroes) |> ignore
  sess.insert_record(teams, { id: 1, name: "avengers" }) |> ignore
  sess.insert_record(heroes, { id: 10, name: "iron-man", team_id: 1 }) |> ignore

  // 1:N — a team's heroes, eagerly loaded as mapped records.
  let children = @moonorm.has_many(heroes, "team_id", (t : Team) => @moondb.Int(t.id))
  let kids = sess.load({ id: 1, name: "avengers" }, children)

  // N:1 — a hero's team.
  let parent = @moonorm.belongs_to(teams, "id", (h : Hero) => @moondb.Int(h.team_id))
  let team = sess.load_one({ id: 10, name: "iron-man", team_id: 1 }, parent)
  ignore((kids, team))
}
```

The relationship's match value is bound, never spliced, so eager loading is
injection-safe like every other query.

### Declarative models from a field list

Writing `to_columns` by hand repeats what the columns already say.
`Model::from_fields` takes that other half off you: give it a list of `field`s —
each a column plus the one-line projection that reads it off a record — and it
derives the column list, the `CREATE TABLE` DDL, the `SELECT` projection, and the
`INSERT` binding. You still supply `from_row`, because turning a fetched row back
into a `T` needs the record constructor, which MoonBit cannot synthesise without
reflection; that one closure is the irreducible core of the mapping. A field
binds anything that converts to a `Value` (moondb's `ToValue`), so the projection
is the attribute itself and `T?` binds `None` as `NULL`:

```moonbit
pub struct Hero {
  id : Int
  name : String
  team_id : Int
}

pub fn declarative() -> @moonorm.Model[Hero] {
  @moonorm.Model::from_fields(
    "heroes",
    [
      @moonorm.field("id", IntType, h => h.id, primary_key=true),
      @moonorm.field("name", TextType, h => h.name, nullable=false),
      @moonorm.field("team_id", IntType, h => h.team_id, references=("teams", "id")),
    ],
    (r) => { { id: r.read(0), name: r.read(1), team_id: r.read(2) } },
  )
}
```

An autoincrement key that is still `None` is left out of the `INSERT`, so the
database assigns it.

### Annotations

`#orm` annotations write that model for you. The generator reads a struct and
emits `T::model()`, the same `from_fields` call as above:

<!-- nocheck -->
```moonbit
#orm.table(name="heroes")
pub struct Hero {
  #orm.column(primary_key=true, autoincrement=true)
  id : Int64?
  name : String
  #orm.column(name="secret_name", unique=true)
  secret : String
  #orm.column(check="age >= 0")
  age : Int?
  #orm.column(references="teams.id", on_delete="SET NULL")
  team_id : Int64?
  #orm.skip
  visits : Int
}
```

<!-- nocheck -->
```moonbit
let hero = Hero::model()   // @moonorm.Model[Hero]
```

A field without annotations is a column named after it, `NOT NULL` unless its
type is `T?`. The table is named `name=`, or the struct's name in snake case.

| Field type | Column type |
|:--:|:--:|
| `Int` | `IntType` |
| `Int64` | `BigIntType` |
| `Double` | `RealType` |
| `String` | `TextType` |
| `Bytes` | `BlobType` |
| `Bool` | `BoolType` |

| `#orm.column` argument | Meaning |
|:--:|:--|
| `name` | the column's name |
| `kind` | the column type by its SQL name: `int`, `bigint`, `text`, `real`, `blob`, `bool`, `varchar(N)`, `numeric`, `datetime`, `date`, `time`, `uuid`, `json` |
| `primary_key`, `unique` | the constraints |
| `autoincrement` | on an integer primary key of type `T?`; `None` until the database assigns it |
| `default` | the SQL default, written as SQL |
| `check` | a `CHECK` constraint; repeat it for several |
| `references` | a foreign key, `"table.column"`, with `on_delete` and `on_update` |
| `index` | an index over this column alone |

Beside `#orm.table`, a struct takes indexes and relations:

| On the struct | Becomes |
|:--:|:--|
| `#orm.index(column="a", column="b", unique=true, name="...")` | an `Index` on the model; `Session::create_table` creates it, named `ix_<table>_<columns>` (`uq_` when unique) unless named |
| `#orm.has_many(name="heroes", target="Hero", foreign_key="team_id")` | `Team::heroes()`, a `Relation` loaded with `Session::load`; `key=` names the field holding this side's key when the primary key is not a single field |
| `#orm.belongs_to(name="team", target="Team", foreign_key="team_id")` | `Hero::team()`, loaded with `Session::load_one`; `key=` names the target's column when the target is not annotated in the same file |

`#orm.skip` keeps a field out of the table and fills it from `Default` when a row
is read. A field of a type of the program's own names its column type with
`kind=` and implements `@moonorm.ToValue` and `@moonorm.FromValue`; see
[`22-annotations`](src/examples/22-annotations/), which also checks the generated
model against the same model written by hand.

Wire the generator into the build once. In `moon.mod`:

<!-- nocheck -->
```
rule(name: "orm", command: "moonx moonbitstack/moonorm/cmd/orm@0.11.2 -C \"$mod_dir\" \"$input\" -o \"$output\"")
```

and in the `moon.pkg` of the package holding the structs:

<!-- nocheck -->
```
dev_build(rule: "orm", input: "models.mbt", output: "models.g.mbt")
formatter(ignore: [ "models.g.mbt" ])
```

`moon check`, `moon build` and `moon run` regenerate `models.g.mbt` whenever
`models.mbt` changes; `--check` reports a stale file instead of writing it.

### Batch loading

Calling `load` once per parent is the N+1 trap — one SELECT per row. `load_batch`
fetches the children of *many* parents in a single `WHERE fk IN (…)` round trip
and buckets them back, index-aligned with the sources you passed.
`load_one_batch` is the N:1 counterpart. Against the models declared above:

<!-- nocheck -->
```moonbit
pub struct Team {
  id : Int
  name : String
}

pub struct Hero {
  id : Int
  name : String
  team_id : Int
}

pub fn batch(
  sess : @moonorm.Session,
  heroes : @moonorm.Model[Hero],
  teams : Array[Team],
) -> Array[Array[Hero]] raise @moondb.DbError {
  let children = @moonorm.has_many(heroes, "team_id", (t : Team) => @moondb.Int(t.id))
  sess.load_batch(teams, children) // one query; result[0] is the first team's heroes
}
```

### Nested transactions & isolation

`begin_nested` opens a SAVEPOINT and hands back a handle that names and
depth-tracks it: finish it with `release` to keep the work or `rollback` to
discard it back to the savepoint, both terminal and idempotent. For an isolation
level or a read-only transaction, `begin_with` renders the backend's
`SET TRANSACTION` (or SQLite `PRAGMA`) and orders it correctly around `BEGIN` per
dialect:

```moonbit
pub fn tx(sess : @moonorm.Session, stmt : @query.Insert, dialect : @query.Dialect) -> Unit raise @moondb.DbError {
  let sp = sess.begin_nested() // SAVEPOINT moonorm_sp_1; sess.savepoint_depth() == 1
  sess.add(stmt) |> ignore
  sp.rollback() // undo just this savepoint's work; depth back to 0

  sess.begin_with({ isolation: Some(Serializable), read_only: false }, dialect~)
  // BEGIN; SET TRANSACTION ISOLATION LEVEL SERIALIZABLE
}
```

### Design and boundaries

- **Explicit, not magic.** Every statement is issued explicitly through a
  `Session`. MoonBit has no attribute interception, so a mapped attribute cannot
  quietly fire SQL; reading a relationship is a call you can see.
- **Pure, zero C.** The library is written entirely against the `@moondb` seam, so
  it compiles on every backend (`wasm` / `wasm-gc` / `js` / `native`) and drags no
  backend behind it. The C lives where a driver needs it —
  [`moonsqlite`](https://github.com/moonbitstack/moondb/tree/master/drivers/sqlite) — never here.
- **Errors raise.** A decode mismatch or a backend rejection is a `@moondb.DbError`
  at the call site, not a zero value.

## Subqueries, CTEs & optimistic locking

The builder does `WITH` common table expressions and `IN (subquery)` predicates,
and both keep the binding guarantee — a subquery's values splice into the params
list in the exact left-to-right order they appear in the SQL text:

```moonbit
pub fn cte() -> (String, Array[@moondb.Value]) {
  let big = @moonorm.select("orders").column("user_id").where_("total", ">", @moondb.Int(100))
  @moonorm.select("users")
  .column("id")
  .column("name")
  .with_cte("big_spenders", big)
  .where_("active", "=", @moondb.Bool(true))
  .where_in("id", @moonorm.select("big_spenders").column("user_id"))
  .build()
  // WITH big_spenders AS (SELECT user_id FROM orders WHERE total > ?)
  //   SELECT id, name FROM users WHERE active = ? AND id IN (SELECT user_id FROM big_spenders)
  // params: [Int(100), Bool(true)]   <- the CTE value first, then the WHERE value
}
```

Optimistic concurrency control: write an UPDATE that bumps the version and guards
on the one you read; `modify_versioned` runs it and raises `LostUpdate` if no row
matched — the update was lost to a concurrent writer:

```moonbit
pub fn optimistic(sess : @moonorm.Session, current : Int) -> Unit raise {
  let stmt = @moonorm.update("account")
    .set("balance", @moondb.Int(50))
    .set("version", @moondb.Int(current + 1))
    .where_("id", "=", @moondb.Int(1))
    .where_("version", "=", @moondb.Int(current)) // the guard
  sess.modify_versioned(stmt, what="account") |> ignore // raises LostUpdate on a stale version
}
```

## Migrations

Versioned migrations, tracked in a `schema_migrations` table. A `Migration`
carries an integer version plus its `up` and `down` statement lists; a `Migrator`
applies pending versions in ascending order, skips ones already applied (so
re-running is a no-op), rolls back to a target version in descending order, and
reports the current version.

```moonbit
pub fn migrations(sess : @moonorm.Session) -> Unit raise @moondb.DbError {
  let plan : Array[@moonorm.Migration] = [
    {
      version: 1,
      name: "create_users",
      up: ["CREATE TABLE users (id INTEGER PRIMARY KEY)"],
      down: ["DROP TABLE users"],
    },
    {
      version: 2,
      name: "add_email",
      up: ["ALTER TABLE users ADD COLUMN email TEXT"],
      down: ["ALTER TABLE users DROP COLUMN email"],
    },
  ]
  let m = @moonorm.Migrator::new()
  m.up(sess, plan) |> ignore // applies 1 then 2; returns how many ran
  let _ = m.current_version(sess) // 2
  m.down_to(sess, plan, 1) |> ignore // rolls back 2, leaving 1
}
```

To go the other way — from what a live database has to what your model declares —
reflect the table and diff it:

```moonbit
pub fn plan_for(db : &@moondb.Driver, declared : Array[@moonorm.Column]) -> Array[@moonorm.ColumnDiff] raise @moondb.DbError {
  let reflected = @moonorm.reflect_table(db, "accounts")
  @moonorm.diff_schema(declared, reflected, dialect=Postgres)
  // Added(name~, col_type~) for a column only the model declares,
  // Removed(name) for one only the database has,
  // TypeChanged(name~, from~, to~) when the two disagree on the type.
}
```

## Injection safety

```moonbit
pub fn injection() -> (String, Array[@moondb.Value]) {
  let evil = "'; DROP TABLE users; --"
  @moonorm.select("users").eq("name", @moondb.Text(evil)).build()
  // SELECT * FROM users WHERE name = ?   <- the attack string is not in the SQL
  // params: [Text("'; DROP TABLE users; --")]   <- it is a bound parameter
}
```

## License

Apache-2.0.
