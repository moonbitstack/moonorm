name = "moonbitstack/moonpostgres"

version = "0.6.2"

readme = "README.md"

repository = "https://github.com/moonbitstack/moonorm"

license = "Apache-2.0"

keywords = [ "postgres", "driver", "moondb", "wire", "database" ]

description = "Pure-MoonBit PostgreSQL wire-protocol driver implementing @moondb.AsyncDriver — no C, like asyncpg."

preferred_target = "native"

import {
  "moonbitstack/moondb@0.2.0",
  "moonbitstack/moonvar@0.2.0",
  "moonbitstack/moonbase@0.4.0",
  "moonbitstack/mooncrypt@0.3.1",
  "moonbitlang/async@0.20.3",
}
