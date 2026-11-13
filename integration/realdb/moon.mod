name = "moonbitstack/moonorm-realdb"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/moonbitstack/moonorm"

license = "Apache-2.0"

keywords = [
  "moonorm",
  "migration",
  "sqlite",
  "postgres",
  "mysql",
  "integration",
]

description = "Real-database round trips for the migration runner, the hybrids and the inheritance mappings, against the working tree."

import {
  "moonbitstack/moonorm@0.11.7",
  "moonbitstack/moonsqlite@0.4.0",
  "moonbitstack/moondb@0.3.0",
  "moonbitstack/moonpostgres@0.7.0",
  "moonbitstack/moonmysql@0.8.0",
  "moonbitlang/async@0.22.5",
}

source = "src"
