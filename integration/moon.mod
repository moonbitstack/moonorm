name = "Lfan-ke/moonorm-integration"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/moonbitstack/moonorm"

license = "Apache-2.0"

keywords = [ "moonorm", "sqlite", "integration", "test", "moonbit" ]

description = "End-to-end integration tests wiring published moonorm + moonsqlite against a real SQLite file. Not published; exists so CI proves the ORM runs migrations and a Session over a real backend."

import {
  "Lfan-ke/moonorm@0.6.3",
  "Lfan-ke/moonsqlite@0.3.0",
  "Lfan-ke/moondb@0.1.4",
}
