name = "moonbitstack/moonpostgres"

version = "0.5.0"

readme = "README.md"

repository = "https://github.com/moonbitstack/moonorm"

license = "Apache-2.0"

keywords = [ "postgres", "driver", "moondb", "wire", "database" ]

description = "Pure-MoonBit PostgreSQL wire-protocol driver implementing @moondb.AsyncDriver — no C, like asyncpg."

preferred_target = "native"

import {
  "moonbitstack/moondb@0.1.8",
  "moonbitstack/moonbase@0.4.0",
  "moonbitlang/async@0.20.3",
}
