# Examples

Runnable `main` packages that exercise the public `@moonorm` API. Each folder builds a
statement, prints the generated SQL and its bound params, and — where it helps — runs
it through a `Session` and prints the rows or the effect.

```bash
moon run examples/00-recursive-cte
```

Together they cover the whole surface: the query builder (`SELECT` projection, filters,
joins, grouping, set operations, window functions, subqueries, recursive CTEs, row
locks), `INSERT` / `UPDATE` / `DELETE` with upserts, the model/session execution layer
(declarative mapping, relationships with eager loading, transactions, savepoints,
isolation, optimistic locking, streaming), schema DDL, migrations, reflection, and the
connection pool.

| # | Example | What it shows | Key API |
| --- | --- | --- | --- |
| 00 | [`recursive-cte`](00-recursive-cte/) | A `Model` over a self-referential table, a filtered `SELECT`, and a `WITH RECURSIVE` subtree walk — then the same builders driving a `Session` | `Model::new`, `Model::select`, `with_recursive`, `Session::insert_record`, `all` |
| 01 | [`select-basics`](01-select-basics/) | Projection (`column` / `raw` / `count`), the `eq` / `where_` filter chain, `ORDER BY` both ways, `LIMIT` / `OFFSET`, and a `Table` descriptor | `select`, `column`, `raw`, `count`, `eq`, `where_`, `order_by`, `limit`, `offset`, `Table::select` |
| 02 | [`join-aggregate`](02-join-aggregate/) | An inner `JOIN` and a `LEFT JOIN`, `GROUP BY`, and `HAVING` on an aggregate (which binds like a `WHERE`) | `join`, `left_join`, `group_by`, `having`, `count` |
| 03 | [`set-operations`](03-set-operations/) | `DISTINCT` and `UNION` / `UNION ALL` / `INTERSECT` / `EXCEPT`, with a trailing `ORDER BY` / `LIMIT` on the compound | `distinct`, `union`, `union_all`, `intersect`, `except_` |
| 04 | [`window-functions`](04-window-functions/) | `<expr> OVER (PARTITION BY … ORDER BY …)`, optionally aliased | `window` |
| 05 | [`predicate-trees`](05-predicate-trees/) | Boolean `AND` / `OR` / `NOT` predicate trees, `InList`, and `Predicate::build` | `Predicate`, `where_pred`, `Predicate::build` |
| 06 | [`subqueries`](06-subqueries/) | CTEs, `IN` / `NOT IN` subqueries, `EXISTS` / `NOT EXISTS`, and `IN (values)` | `with_cte`, `where_in`, `where_exists`, `where_in_values` |
| 07 | [`insert-upsert`](07-insert-upsert/) | Single- and multi-row inserts, `ON CONFLICT` upserts (`do_update` / `do_update_excluded` / `do_nothing`), `RETURNING`, and per-dialect `build_for` | `insert`, `set`, `values`, `on_conflict`, `do_update_excluded`, `returning`, `build_for` |
| 08 | [`update-delete`](08-update-delete/) | `UPDATE` / `DELETE` with `WHERE`, the `= NULL` → `IS NULL` fold, and `Session::modify` / `remove` | `update`, `delete`, `Session::modify`, `remove` |
| 09 | [`row-locking`](09-row-locking/) | `FOR UPDATE` / `FOR SHARE`, `OF`, `NOWAIT`, and `SKIP LOCKED` (SQLAlchemy `with_for_update`) | `for_update` |
| 10 | [`schema-ddl`](10-schema-ddl/) | `CREATE TABLE` per dialect — autoincrement idioms, `UNIQUE` / `DEFAULT` / `CHECK` / foreign keys, a composite primary key, and `CREATE INDEX` | `create_table_sql`, `create_table_sql_for`, `Column::ddl`, `sql_for`, `index_ddl` |
| 11 | [`model-crud`](11-model-crud/) | The declarative `Model` as the CRUD unit: `insert_of`, `column_names`, `table_descriptor`, and a `Session` round trip | `Model::insert_of`, `map_rows`, `Session::create_table`, `insert_record`, `all`, `fetch_as` |
| 12 | [`declarative-fields`](12-declarative-fields/) | `Model::from_fields` deriving the columns, DDL, and `INSERT` binding from a `[Field]` array | `field`, `Model::from_fields`, `Field::name` |
| 13 | [`relationships`](13-relationships/) | `has_many` / `belongs_to` / `many_to_many`, and eager loading — `load` / `load_one` / `load_many` plus the N+1-avoiding `load_batch` / `load_one_batch` | `has_many`, `belongs_to`, `many_to_many`, `batch_query`, `Session::load_batch` |
| 14 | [`transactions`](14-transactions/) | `begin` / `commit` / `rollback` over the MockDriver's faithful bracket — the row count witnesses a real rollback | `Session::begin`, `commit`, `rollback` |
| 15 | [`savepoints`](15-savepoints/) | Nested transactions — `begin_nested` auto-naming and depth-tracking, the raw `savepoint` / `rollback_to` / `release` trio, and the identifier guard | `begin_nested`, `Savepoint`, `savepoint` |
| 16 | [`isolation`](16-isolation/) | `IsolationLevel` keywords, `TxOptions::to_sql` per dialect, and `begin_with` | `IsolationLevel`, `TxOptions`, `begin_with` |
| 17 | [`optimistic-lock`](17-optimistic-lock/) | `modify_versioned` running a version-guarded `UPDATE` and raising `LostUpdate` on a stale write | `modify_versioned`, `LostUpdate` |
| 18 | [`streaming`](18-streaming/) | Bounded-memory reads: `stream_as` (typed `RowStream`), `stream` (raw cursor), and `query_stream` | `stream_as`, `RowStream`, `stream`, `query_stream` |
| 19 | [`migrations`](19-migrations/) | A `Migrator` applying and rolling back `Migration`s (idempotent `up`, `down_to`), with `current_version` / `applied_versions` | `Migrator`, `Migration`, `up`, `down_to` |
| 20 | [`reflection-diff`](20-reflection-diff/) | Reflecting columns from SQLite / PostgreSQL / MySQL metadata rows, `diff_schema`, and `index_ddl` | `reflect_columns`, `reflect_table`, `diff_schema`, `index_ddl` |
| 21 | [`pool`](21-pool/) | The connection pool — `acquire` / `release` / `try_acquire` / `with_conn` — and `Session::with_pool` | `@moondb.Pool`, `with_conn`, `Session::with_pool` |

Values never enter the SQL string: every bound value becomes a `?` placeholder and one
entry in the params list, in text order — so a bulk insert, an upsert, a subquery, or an
eager load is injection-safe by construction.

Most examples run against `@moondb.MockDriver`, a dependency-free store that models the
transaction bracket faithfully (so `14-transactions` shows a real rollback) and compiles
on every backend. A few — `13-relationships`, `17-optimistic-lock`, `19-migrations`,
`20-reflection-diff` — implement a tiny `@moondb.Driver` in the example itself (a
fixed-rows result set or a small bookkeeping table) to drive logic the echo store cannot,
without pulling in a native backend. For real SQL, point a `Session` at a concrete
`@moondb.Driver` — the native SQLite driver lives in
[`moonsqlite`](https://github.com/moonbitstack/moonorm/tree/master/drivers/sqlite); the builders are identical.
