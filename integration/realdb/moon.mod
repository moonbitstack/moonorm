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
  "moonbitstack/moonsqlite@0.3.5",
  "moonbitstack/moondb@0.2.6",
  "moonbitstack/moonpostgres@0.6.9",
  "moonbitstack/moonmysql@0.7.9",
  "moonbitlang/async@0.22.7",
}

source = "src"
