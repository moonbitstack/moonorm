<div align="center">

# moonorm

[Site](https://moonbitstack.github.io/moonorm/) ·
[Guide](https://moonbitstack.github.io/moonorm/guide.html) ·
[API](https://moonbitstack.github.io/moonorm/api.html) ·
[mooncakes](https://mooncakes.io/docs/moonbitstack/moonorm)

**An ORM and SQL toolkit for MoonBit: a typed schema, three dialects, values that are always bound, and a migration history that can branch.**

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
| `moonorm/schema` | `ColumnType`, `Column`, `Field`, `Model`, `Relation`, `ManyToMany`, `TableSpec`, the three inheritance mappings, table and index DDL | `query`, moondb |
| `moonorm/session` | `Session` and `AsyncSession`, row streams, transactions and savepoints, the unit of work, event hooks, pooled sessions | `schema`, `query`, moondb |
| `moonorm/migrate` | `Migration`, `Revision`, `Op`, `Migrator`, `ColumnDiff`, reflection, diffing and autogenerate | `session`, `schema`, `query` |
| `moonorm/engine` | `Engine`, `Dsn`, `DsnError`: a connection string names the driver and the dialect | `query`, `session`, moondb |
| `moonorm/mapper` | the runtime behind `#sql.*`: reads a row into what a mapper function returns | moondb |
| `moonorm/cmd/orm` | the generator behind `#orm.table`, `#orm.column`, `#orm.skip`, `#orm.index`, `#orm.has_many` and `#orm.belongs_to` | moonast |

A program that only renders SQL imports `query` and nothing else.

**Constructors are written without the package.** `pub using` re-exports types but
not their constructors, so `@moonorm.Postgres` does not resolve. Write the bare
constructor and let the expected type pick it: `stmt.build_for(Postgres)`. Where
nothing gives the type, annotate or name the subpackage:
`let levels : Array[@moonorm.IsolationLevel] = [ReadCommitted, Serializable]`, or
`catch { @session.LostUpdate(msg) => ... }`.

## Quickstart

A table is an annotated struct, and a statement an annotated function:

```moonbit
#orm.table(name="champions")
pub struct Champion {
  #orm.column(primary_key=true, autoincrement=true)
  id : Int64?
  name : String
  #orm.column(index=true)
  power : Double
}

#sql.select("SELECT id, name, power FROM champions WHERE power > #{power}")
declare fn strong(db : &@moondb.Driver, power : Double) -> Array[Champion] raise
```

`Champion::model()` is the table for a session and for migrations, and `strong` runs
its statement with `power` bound. Both come from generators run as build rules: see
[Annotations](#annotations) and [SQL mappers](#sql-mappers).

### The query builder

For a query that is put together at run time:

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

<!-- nocheck -->
```moonbit
// native target only — moonsqlite links the vendored amalgamation, and it is a
// separate package (`moonbitstack/moonsqlite`), not a dependency of this one.
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

A session renders for one dialect, SQLite unless told otherwise, because a driver takes SQL and
says nothing about what it speaks. `Session::new(driver, dialect=Mysql)` gives the
`ON DUPLICATE KEY UPDATE` form and no `RETURNING`, and `Session::with_pool` takes the same label.

### A connection string picks the driver and dialect

An `Engine` parses a URL and remembers the dialect its sessions render for. The
scheme names the driver — `sqlite`, `postgresql` (or `postgres`), `mysql` — and a
`+driver` suffix overrides the driver name without changing the dialect. moonorm
supplies no driver, so the session still takes the one you opened:

```moonbit
pub fn from_url(driver : &@moondb.Driver) -> @moonorm.Session raise @moonorm.DsnError {
  let engine = @moonorm.Engine::new("postgresql://user:pass@db:5432/app?sslmode=require")
  // engine.driver() == "postgresql"; engine.dialect() == Postgres
  engine.session(driver) // a Session that renders for Postgres
}
```

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
pub fn mapping(
  sess : @moonorm.Session,
  teams : @moonorm.Model[Team],
  heroes : @moonorm.Model[Hero],
) -> Unit raise @moondb.DbError {
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

A storage type the built-in `ColumnType` variants do not name is declared from its
three spellings. Values still bind through `ToValue`/`FromValue`, so the type is
open end to end:

```moonbit
pub fn handle_column() -> @moonorm.ColumnType {
  @moonorm.user_type(sqlite="TEXT", postgres="CITEXT", mysql="VARCHAR(255)")
}
```

An explicit model takes it as a field's column type, and the annotated form names it with
`kind="handle_column()"`, or writes the storage on the field with `sqlite=`, `postgres=` and `mysql=`
together.

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
`kind="its_function()"`, or with `sqlite=`, `postgres=` and `mysql=`, and implements
`@moonorm.ToValue` and `@moonorm.FromValue`; see
[`22-annotations`](src/examples/22-annotations/), which also checks the generated
model against the same model written by hand.

Wire the generator into the build once. In `moon.mod`:

<!-- nocheck -->
```
rule(name: "orm", command: "moonx moonbitstack/moonorm/cmd/orm@0.12.0 -C \"$mod_dir\" \"$input\" -o \"$output\"")
```

and in the `moon.pkg` of the package holding the structs:

<!-- nocheck -->
```
dev_build(rule: "orm", input: "models.mbt", output: "models.g.mbt")
formatter(ignore: [ "models.g.mbt" ])
```

`moon check`, `moon build` and `moon run` regenerate `models.g.mbt` whenever
`models.mbt` changes; `--check` reports a stale file instead of writing it.

### Without annotations

The generator emits `Model::from_fields`; writing that yourself is the functional
form. The class-style form writes `Model::new` with both mapping closures out in the
open. All three produce the same `Model[T]`, so the rest of a program is unchanged.

Functional — a field list plus one row decoder:

```moonbit
pub struct Fighter {
  id : Int64?
  name : String
  power : Double
}

pub fn fighter_model() -> @moonorm.Model[Fighter] {
  @moonorm.Model::from_fields(
    "heroes",
    [
      @moonorm.field("id", BigIntType, h => h.id, primary_key=true, autoincrement=true),
      @moonorm.field("name", TextType, h => h.name, nullable=false),
      @moonorm.field("power", RealType, h => h.power),
    ],
    (r) => { { id: r.read(0), name: r.read(1), power: r.read(2) } },
  )
}
```

Class-style — the same model with both directions written out:

```moonbit
pub struct Warrior {
  id : Int64?
  name : String
  power : Double
}

pub fn warrior_model() -> @moonorm.Model[Warrior] {
  @moonorm.Model::new(
    "heroes",
    [
      @moonorm.column("id", BigIntType, primary_key=true, autoincrement=true),
      @moonorm.column("name", TextType, nullable=false),
      @moonorm.column("power", RealType),
    ],
    (r) => { { id: r.read(0), name: r.read(1), power: r.read(2) } },
    (h) => {
      let out : Array[(String, @moondb.Value)] = []
      if h.id is Some(v) {
        out.push(("id", @moondb.Int64(v)))
      }
      out.push(("name", @moondb.Text(h.name)))
      out.push(("power", @moondb.Double(h.power)))
      out
    },
  )
}
```

### SQL mappers

When the query is the point, write it. `#sql.*` goes on a `declare fn`, and the
generator gives the function its body:

```moonbit
pub struct User {
  id : Int64
  name : String
  age : Int32?
}

#sql.select("SELECT id, name, age FROM user WHERE age > #{age}")
declare fn adults(db : &@moondb.Driver, age : Int32) -> Array[User] raise

#sql.select("SELECT id, name, age FROM user WHERE id = #{id}")
declare fn find(db : &@moondb.Driver, id : Int64) -> User? raise

#sql.insert("INSERT INTO user(name, age) VALUES(#{u.name}, #{u.age})")
declare fn add(db : &@moondb.Driver, u : User) -> Int64 raise

#sql.delete("DELETE FROM user WHERE id = #{id}")
declare fn remove(db : &@moondb.Driver, id : Int64) -> Unit raise
```

`#{name}` and `#{name.field}` are bound values, in the order they appear, and
there is no way to splice text into a statement: a `${...}` or a placeholder written
by hand is refused when the code is generated. `dialect="postgres"` numbers the
placeholders, and `sqlite` and `mysql` write `?`.

| Annotation | Means |
|:--:|:--|
| `#sql.select(sql)` | runs a query; what the function returns says how the rows are read |
| `#sql.insert(sql, returning="id")` | an `Int64` return is the new id, by `RETURNING` when asked and the driver's last id otherwise |
| `#sql.update(sql)`, `#sql.delete(sql)` | an `Int64` return is the rows touched, `Unit` drops it |
| `#sql.results(column="user_name", field="name")` | a column with another name than its field |

| A select returning | Reads |
|:--:|:--|
| `Array[T]` | every row |
| `T?` | at most one row, more is an error |
| `T` | exactly one row, anything else is an error |
| a struct | each field from the column of its name |
| `Int64`, `String` and the other column types | the first column |

A struct field the `SELECT` does not list is refused at generation, unless it is
`T?`. Dynamic SQL belongs to the query builder, which every other part of this
library uses. `async` works the same way, on `declare async fn` and a
`&@moondb.AsyncDriver`. Run a mapper inside a transaction by passing the session's
driver.

The generator wires in like the other one, with `cmd/sql` and the package importing
`moonbitstack/moonorm/mapper`:

<!-- nocheck -->
```
rule(name: "sql", command: "moonx moonbitstack/moonorm/cmd/sql@0.12.0 -C \"$mod_dir\" \"$input\" -o \"$output\"")
dev_build(rule: "sql", input: "models.mbt", output: "mapper.g.mbt")
```

[`23-sql-mapper`](src/examples/23-sql-mapper/) runs each of these against a driver
that logs what it is asked.

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

`load`, `load_one`, `load_batch`, `load_one_batch` and `load_many` take a
`strategy` — `SubqueryLoad` (the default, one `IN` query), `JoinedLoad` (a JOIN
against a derived table of the source keys) or `RaiseLoad` (refuse, so a caller can
assert a relation is not touched here). `load_many_batch` batches an N:M relation
through its junction the same way:

<!-- nocheck -->
```moonbit
sess.load_batch(teams, children, strategy=JoinedLoad)
```

### Nested transactions & isolation

`begin_nested` opens a SAVEPOINT and hands back a handle that names and
depth-tracks it: finish it with `release` to keep the work or `rollback` to
discard it back to the savepoint, both terminal and idempotent. A rollback takes the
session with it: writes queued after the savepoint opened leave the queues, and the
identity map returns to the records it held then, so a later `flush` cannot write a
row the database has just undone and a `get` cannot hand out a record whose row is
gone. A released savepoint keeps its work, and an outer rollback still drops it.

For an isolation level or a read-only transaction, `begin_with` renders the backend's
`SET TRANSACTION` (or SQLite `PRAGMA`) and orders it correctly around `BEGIN` per
dialect. SQLite's `PRAGMA`s live on the connection rather than the transaction, so
`commit` and `rollback` put `query_only` and `read_uncommitted` back before the
connection goes on to its next borrower — otherwise a read-only transaction would
leave a pooled connection that cannot write:

```moonbit
pub fn tx(sess : @moonorm.Session, stmt : @query.Insert) -> Unit raise @moondb.DbError {
  let sp = sess.begin_nested() // SAVEPOINT moonorm_sp_1; sess.savepoint_depth() == 1
  sess.add(stmt) |> ignore
  sp.rollback() // undo just this savepoint's work; depth back to 0

  sess.begin_with({ isolation: Some(Serializable), read_only: false })
  // BEGIN; SET TRANSACTION ISOLATION LEVEL SERIALIZABLE
}
```

## Asynchronous sessions

An `AsyncSession` is the same unit of work over an `@moondb.AsyncDriver`. It exists
because a wire backend only ever implements the asynchronous seam: PostgreSQL over a
socket and MySQL through `moonbitlang/async` cannot be reached through a blocking
`Session` at all. Every method of `Session` has the same name here, awaited, and the
state behind both — queues, dependency order, identity map, savepoint marks — is one
implementation, so the two cannot drift apart:

```moonbit
pub async fn async_unit(driver : &@moondb.AsyncDriver) -> Unit raise {
  let sess = @moonorm.AsyncSession::new(driver, dialect=Postgres)
  sess.begin()
  sess.add_all(fighter_model(), [{ id: Some(1L), name: "Ada", power: 9.5 }])
  sess.commit()
  let rows = sess.all(fighter_model())
  assert_eq(rows.length(), 1)
}
```

One session is one connection and runs one statement at a time, so concurrency comes
from running several. `AsyncSession::with_pool` takes a connection from an
`@apool.AsyncPool`, hands it to a session and returns it when the work finishes or
raises, which is what lets two tasks have two queries in flight:

```moonbit
pub async fn[D : @moondb.AsyncDriver] pooled(
  pool : @apool.AsyncPool[D],
) -> Array[@moondb.Row] raise @moondb.DbError {
  @moonorm.AsyncSession::with_pool(pool, sess => {
    sess.query("SELECT 1", [])
  })
}
```

Two tasks that call `pooled` at once take two connections and their statements
overlap; the test in `integration/realdb` proves it on a live server by running two
`SELECT pg_sleep(0.3)` statements and requiring the pair to finish inside 550 ms,
which is what a sequential run would exceed.

`query_stream` and `stream_as` hand back an `@moondb.AsyncCursor` and an
`AsyncRowStream`, so a large read is pulled off the wire a row at a time; the
synchronous `Session` cannot offer that to a networked backend. Savepoints, isolation
options, event hooks, `merge`, `refresh` and the batch loaders are all present with
the same names and the same semantics.

## Consistency

Two independent implementations are the reference, and both run in CI. SQLAlchemy
2.0 is the ORM reference: the examples in its own ORM documentation are transcribed
into `integration/realdb` (`orm_tutorial*.mbt`), run on SQLite through `Session` and
on PostgreSQL 16 and MySQL 8 through `AsyncSession`, and each run has to produce the
same transcript — the filtered read, the ordered read, the relationship join with
`GROUP BY`, the eager load, the update and the delete. All three agree. Alembic 1.16
is the reference for the migrations.

Neither ships a conformance runner, so `integration/reference` holds a differential
instead, and the `realdb` job runs it against both:

- **The same ten queries.** Both implementations declare the same two tables with
  the storage this library gives them on SQLite, seed the same rows and answer the
  same ten questions: an inner join with `GROUP BY` and `HAVING`, a left join with a
  null test, `DISTINCT`, `coalesce`, `MAX`, a window function, `LIKE`, an upsert and a
  cascading delete. The rows have to match line for line.
- **The same schema.** The two databases are compared through SQLite's own pragmas —
  the storage class of each column, nullability, key membership, defaults, the
  indexes the declaration asked for, and the foreign keys with their actions.
- **The same migration.** One model change — a table and a column appear, a column
  and an index disappear, a storage type changes — read by Alembic's autogenerate and
  by `autogenerate_changes`; the two lists of operations have to be the same list.
- **Both directions at run time.** SQLAlchemy reflects the database this library
  created, finds the declared columns, key, index and foreign key, and reads its rows;
  this library reflects the one SQLAlchemy created, and the reads it answers from it
  match the transcript.

The vectors the comparisons replay are generated from those runs by
`scripts/gen_reference_vectors.py`, and CI regenerates them and fails when the tree
holds anything else.

What the comparison cannot carry, and why:

| Reference feature | Here |
|:--|:--|
| attribute interception (`user.addresses` fires a SELECT) | no interception in MoonBit; `Session::load` / `load_batch` are explicit calls, as Diesel and GORM require |
| polymorphic instance dispatch (a base read returns subclass instances) | no downcast; a base read returns base records, and the record type decides which columns exist |
| `automap`, `declarative_base` from a live schema | no runtime-typed records; models are declared or generated from annotations (`#orm.table`) |
| `Session.delete` cascading to loaded children | no unit-of-work graph over Python objects; delete the children explicitly, or let the foreign key's `ON DELETE` do it |
| mutable tracked collections (`MutableList`, `MutableDict`) | records are values; hand a changed record to `update_record` rather than tracking in place |
| column defaults and foreign keys in autogenerate | reflection reports a column's storage class, nullability and key, so `autogenerate_changes` generates creates, drops, type and nullability changes, and index changes — a default or a foreign key that moved is not detected |
| the schema differential on the servers | it runs on SQLite, where the two implementations can both build the file; on PostgreSQL and MySQL the transcript above is the equal-output check |

Everything else the ORM documentation exercises — filtered and ordered selects,
aggregate joins, eager and batched loading, savepoints, unit-of-work flush ordering,
identity map, optimistic locking, hybrid attributes, the three inheritance mappings,
schema reflection and the migration history — is implemented and covered by the
module's tests, which run against the three real engines in CI.

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

## Event hooks

A session fires at eleven points in its write path: before and after each insert,
update and delete, around the flush, and around the transaction. One context is
handed to every listener — the table, the row about to be written, and, for an
`After*` hook, the statement that ran with its bound values.

```moonbit
pub fn stamp_audit(sess : @moonorm.Session) -> Unit {
  sess.on(BeforeInsert, ctx => {
    // The row is mutable here: what the hook leaves behind is what gets written.
    ctx.set_column("updated_by", @moondb.Text("nightly-job"))
  })
  sess.on(BeforeInsert, ctx => {
    if ctx.table != "audit_log" {
      return
    }
    ctx.set_column("at", @moondb.Text("now"))
  })
  sess.on(AfterInsert, ctx => println(ctx.sql))
}
```

`set_column` replaces a value the row already carries or appends one it does not;
`set_columns` swaps the whole list. A handler that raises aborts the flush before
the statement is sent, and the row stays queued, so a refused flush is not a lost
row. `Session::listener_count` and `Session::off_all` manage a session's listeners;
listeners belong to the session that registered them and run in registration order.

The names follow the SQLAlchemy events of the same spelling. A mapper-level listener
there is a session listener here that checks `ctx.table`, since this layer has no
mapper object to register on.

## Hybrid attributes

A hybrid is one definition read two ways: as SQL for filtering and ordering, and as
a value computed off a record. Writing it once is what stops the two readings from
drifting apart.

```moonbit
pub struct Person {
  id : Int32
  first : String
  last : String
}

pub fn person_row(r : @moondb.Row) -> Person raise @moondb.DbError {
  { id: r.int(0), first: r.text(1), last: r.text(2) }
}

pub fn person_model() -> @moonorm.Model[Person] {
  @moonorm.Model::from_fields(
    "people",
    [
      @moonorm.field("id", IntType, p => p.id, primary_key=true),
      @moonorm.field("first", TextType, p => p.first, nullable=false),
      @moonorm.field("last", TextType, p => p.last, nullable=false),
    ],
    person_row,
  )
}

pub fn full_name() -> @moonorm.Hybrid[Person] {
  @moonorm.hybrid(
    "full_name",
    "{t}.first || ' ' || {t}.last",
    p => @moondb.Text(p.first + " " + p.last),
  )
}

pub fn adult_query(people : @moonorm.Model[Person]) -> @moonorm.Select raise @moondb.DbError {
  people.select().where_hybrid(full_name(), "=", @moondb.Text("Ada Lovelace"))
  // SELECT id, first, last FROM people WHERE people.first || ' ' || people.last = ?
}
```

`{t}` is the table qualifier: `where_hybrid`, `order_hybrid` and `project_hybrid`
fill it with the query's own table, or with the `table=` you pass when the query
joins. A query that reads from a derived table has no name to fill in, and asking for
one there raises rather than splicing a `{t}` into SQL the server would reject.
`Hybrid::value` is the in-memory reading, and the two are expected to agree — that is
what the tests compare, on a real database.

## Inheritance mapping

A class hierarchy is stored three ways, and each is one `Model` over one record type.

**Single table.** The whole hierarchy lives in one table behind a discriminator.
`discriminate` filters reads on it and forces it into inserts, so a subclass row
cannot be written as a base row by accident.

```moonbit
pub struct Engineer {
  id : Int32
  name : String
  engineer_name : String
}

pub fn engineer_row(r : @moondb.Row) -> Engineer raise @moondb.DbError {
  { id: r.int(0), name: r.text(1), engineer_name: r.text(2) }
}

pub fn engineer_model() -> @moonorm.Model[Engineer] {
  let fields : Array[@moonorm.Field[Engineer]] = [
    @moonorm.field("id", IntType, e => e.id, primary_key=true),
    @moonorm.field("name", TextType, e => e.name, nullable=false),
    @moonorm.field("engineer_name", TextType, e => e.engineer_name),
  ]
  @moonorm.Model::from_fields("employee", fields, engineer_row)
  .discriminate(column="kind", identity="engineer")
  // SELECT id, name, engineer_name, kind FROM employee WHERE kind = ?
}
```

The base model still reads every row of the table; each subclass model reads only its
own.

**Joined table.** Each class's own columns live in its own table, joined on the key.
`joined` projects the parent's columns qualified and then the subclass's, joins the
parent, and splits writes: an insert writes the parent row and then the subclass row,
which is the only order the foreign key allows, and a delete takes them in the
opposite order.

```moonbit
pub struct JoinedEngineer {
  id : Int32
  name : String
  engineer_name : String
}

pub fn joined_engineer_row(r : @moondb.Row) -> JoinedEngineer raise @moondb.DbError {
  { id: r.int(0), name: r.text(1), engineer_name: r.text(2) }
}

pub fn engineer_fields() -> Array[@moonorm.Field[JoinedEngineer]] {
  [
    @moonorm.field("id", IntType, e => e.id, primary_key=true),
    @moonorm.field("engineer_name", TextType, e => e.engineer_name),
  ]
}

pub fn joined_engineer_model() -> @moonorm.Model[JoinedEngineer] {
  @moonorm.Model::from_fields("engineer", engineer_fields(), joined_engineer_row)
  .joined(parent_table="person", parent_columns=["id", "name"])
  // SELECT person.id, person.name, engineer.engineer_name
  //   FROM engineer JOIN person ON person.id = engineer.id
}
```

**Concrete table.** Every class has a table with all of its columns and there is no
shared table to join through, so each class is simply its own model, and a
polymorphic read is the union of the per-class reads:

```moonbit
pub fn everyone(engineers : @moonorm.Select, managers : @moonorm.Select) -> @moonorm.Select {
  engineers.union_all(managers)
}
```

There is no instance dispatch in any of the three: MoonBit has no downcast, so a base
read returns base records. Which columns exist is decided by the record type, which
tables they come from by the model.

## Migrations

Two shapes, for two jobs.

### Versioned steps

The simple form: a `Migration` carries an integer version plus its `up` and `down`
statement lists; a `Migrator` applies pending versions in ascending order, skips the
ones already applied (so re-running is a no-op), rolls back to a target version in
descending order, and reports the current version.

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

### Revisions

An integer cannot express two people branching from the same point and merging
later, so the full form is a graph: a `Revision` names its `parents` — none for a
base, one for a step, two or more for a merge — and a change is a list of `Op` values
rather than SQL text.

```moonbit
pub fn revisions() -> Array[@moonorm.Revision] {
  [
    @moonorm.Revision::new(
      id="0001",
      name="create_heroes",
      up=[
        @moonorm.create_table("heroes", [
          @moonorm.column("id", IntType, primary_key=true, autoincrement=true),
          @moonorm.column("name", TextType, nullable=false),
        ]),
        @moonorm.create_index("ix_heroes_name", "heroes", ["name"]),
      ],
      down=[
        @moonorm.drop_index("ix_heroes_name"),
        @moonorm.drop_table("heroes"),
      ],
    ),
    @moonorm.Revision::new(
      id="0002",
      parents=["0001"],
      name="create_teams",
      up=[
        @moonorm.create_table("teams", [
          @moonorm.column("id", IntType, primary_key=true, autoincrement=true),
          @moonorm.column("name", TextType, nullable=false),
        ]),
      ],
      down=[@moonorm.drop_table("teams")],
    ),
  ]
}
```

The operations are `create_table`, `drop_table`, `add_column`, `drop_column`,
`rename_table`, `rename_column`, `alter_column`, `add_foreign_key`,
`drop_foreign_key`, `create_index`, `drop_index`, `rebuild_table` and `execute`. Being
values, they render for any dialect, compare in a test, and can be printed before
anything runs.

```moonbit
pub fn apply(sess : @moonorm.Session, plan : Array[@moonorm.Revision]) -> Unit raise @moondb.DbError {
  let m = @moonorm.Migrator::new()
  m.upgrade(sess, plan) |> ignore        // to the single head; "heads" for every tip
  m.downgrade(sess, plan, target="0001") |> ignore
  m.stamp(sess, plan, target="0002") |> ignore  // record it without running it
  let _ = m.heads(sess, plan)            // where the database sits
  let _ = m.history(sess, plan)          // newest first, each marked applied
}
```

Each revision and the row that records it run in one transaction, so an interrupted
upgrade resumes at a revision boundary. Running the same set twice applies nothing.

`upgrade_sql` and `downgrade_sql` return exactly the statements the online path
executes, which is the offline mode and what a driver behind an async seam runs:

```moonbit
pub fn plan_sql(plan : Array[@moonorm.Revision]) -> Array[@moonorm.Step] raise @moondb.DbError {
  @moonorm.Migrator::new().upgrade_sql(plan, [], target="heads", dialect=Postgres)
}
```

An engine that cannot express an operation is refused, not approximated: SQLite
cannot add a foreign key or change a column's type in place, and `alter_column` there
raises and points at `rebuild_table`, which is the four-step swap SQLite's batch alter
performs.

### Autogenerate

Compare what the models declare against what the database has, and get the operations
that close the gap — with the operations that undo them:

```moonbit
pub fn drift(declared : Array[@moonorm.TableSpec], live : Array[@moonorm.TableSpec]) -> Array[@moonorm.Change] {
  @moonorm.autogenerate_changes(declared, live, dialect=Postgres)
  // up:   ALTER TABLE heroes ADD COLUMN power INTEGER
  // down: ALTER TABLE heroes DROP COLUMN power
}
```

The comparison covers tables added and dropped, columns added and dropped, type and
nullability changes (types compared as the dialect spells them, so an `Int64` that
SQLite stores as `INTEGER` is not a change), and indexes added, dropped and replaced.
`TableSpec` is a model without its record type — `model.spec()` produces one — and
`reflect_schema(driver, dialect)` produces the other side.

Because every change carries its inverse, `autogenerate_revision` produces a revision
with a downgrade already written:

```moonbit
pub fn next_revision(declared : Array[@moonorm.TableSpec], live : Array[@moonorm.TableSpec]) -> @moonorm.Revision {
  @moonorm.autogenerate_revision(id="0005", parents=["0004"], name="hero powers", declared, live)
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
