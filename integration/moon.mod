name = "moonbitstack/moonorm-integration"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/moonbitstack/moonorm"

license = "Apache-2.0"

keywords = [ "moonorm", "sqlite", "integration", "test", "moonbit" ]

description = "End-to-end integration tests wiring published moonorm + moonsqlite against a real SQLite file. Not published; exists so CI proves the ORM runs migrations and a Session over a real backend."

import {
  "moonbitstack/moonorm@0.8.1",
  "moonbitstack/moonsqlite@0.3.0",
  "moonbitstack/moondb@0.1.8",
}
