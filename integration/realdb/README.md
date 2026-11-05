# moonorm-realdb

Real-database tests for the library in this repository: the revision migrator, the
hybrid attributes and the three inheritance mappings, run against SQLite, PostgreSQL
and MySQL rather than against a driver double.

The module is not published and not part of the library's dependency graph. It pins
`moonorm` by version and relies on a workspace to resolve it to the working tree, so
it tests the code that was checked out:

```
printf 'members = [\n  ".",\n  "./integration/realdb",\n]\n' > ../../moon.work
moon test --target native
```

`moon.work` is generated and never committed. SQLite needs nothing; PostgreSQL and
MySQL need a server, and the connection parameters come from the usual environment
variables (`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`, `MYSQLHOST`,
`MYSQLPORT`, `MYSQLUSER`, `MYSQLPASSWORD`, `MYSQLDATABASE`). With `MOONORM_LIVE` set
the servers must be reachable — a failed connection is a test failure, not a skip —
which is how CI runs it, with `postgres:16` and `mysql:8` service containers.
