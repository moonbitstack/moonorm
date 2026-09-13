`moonorm` is an ORM for MoonBit in the shape of SQLAlchemy: a query builder, sessions, models and migrations, written against the `@moondb` driver seam rather than any one database.

# Working here

This repository is six independent moon modules, not one — there is no `moon.work`, so every command runs from the module's own directory:

| module | target | what it is |
|:--|:--|:--|
| `.` | all | the ORM |
| `db` | all | `moondb`, the driver interface |
| `drivers/sqlite` | native | links the vendored SQLite amalgamation |
| `drivers/postgres` | native | the wire protocol, in MoonBit |
| `drivers/mysql` | all | the wire protocol, in MoonBit |
| `integration` | native | consumes the published packages |

- `moon fmt` before anything else, in every module you touched. CI runs `moon fmt && git diff --exit-code`, so an unformatted file fails the build on its own.
- `moon check --target all --deny-warn` is the gate (`--target native` for the two native modules). Warnings are errors.
- `moon test` likewise per module.
- `moon info` regenerates `pkg.generated.mbti`. If that file does not change, your edit is not visible to anyone depending on the package, which usually means the refactor was safe. Every module tracks its own, so run it in each one you touched; the example packages regenerate theirs, which is why only those are gitignored.
- CI installs the latest moon on every run, so a toolchain that is behind will disagree with it. Upgrade locally rather than pinning.

# Tests against real databases

The driver suites talk to real servers and are gated on environment variables — without them the live tests silently skip and a green run means less than it looks. CI starts the containers and sets the variables: `MOON_PG_TEST` with postgres:16 on scram-sha-256, and `MYSQL_TEST` with mysql:8.0 twice (native password and caching_sha2, the latter on a fresh container so the empty auth cache forces the full RSA path), MariaDB 11 and 10.11, and MariaDB with `client_ed25519`. Reproduce a failure by starting the same container and exporting the same variables.

# Things worth knowing

- The ORM must not reach past `@moondb`. Anything database-specific belongs in a driver; the C lives in `moonsqlite` only.
- Anything holding a connection across a call into user code releases it with `defer`, so it comes back on every path including cancellation. `Session::with_pool` and `Pool::with_conn` are the reference; a `catch` that re-raises is what the compiler's `fragile_catch_all` lint rejects. Where the resource is handed on to the caller on success — the postgres and mysql handshakes — it is `errdefer` instead.
- `.moonignore` keeps `.git/` out of the published package. `.gitignore` un-ignores `.git*` so that `.gitignore` and `.github` stay tracked, and `moon publish` reads the same file, which is how the whole object database used to end up in the tarball.
- `integration/` pins published versions on purpose: it is the check that what is on mooncakes.io actually works together, so bump those deliberately after a release, not as part of a feature.
