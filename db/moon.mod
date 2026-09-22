name = "moonbitstack/moondb"

version = "0.2.0"

readme = "README.md"

repository = "https://github.com/moonbitstack/moonorm"

license = "Apache-2.0"

keywords = [ "database", "sql", "driver", "db-api", "moonbit", "interface" ]

description = "The standard database-access interface for MoonBit — the driver↔query-layer contract, transliterated from Go's database/sql/driver and Python's DB-API 2.0. ORMs (moonorm) build on it; drivers (moonsqlite / moonpostgres / moonmysql) implement it."

preferred_target = "wasm-gc"

import {
  "moonbitstack/moondate@0.1.0",
  "moonbitstack/moonpool@0.2.0",
}
