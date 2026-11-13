// The differential against SQLAlchemy 2.0, and the two directions of interoperability.
//
// `reference_expected.mbt` is generated from a real SQLAlchemy run
// (`scripts/gen_reference_vectors.py`): the schema SQLAlchemy leaves in a SQLite
// file, the rows its ten queries return, and the read-only part of that transcript.
// What this file does is build the same two tables with this library, ask the same ten
// questions, and require the same answers — then read a database SQLAlchemy built and
// leave one for SQLAlchemy to read.
//
// With `MOONORM_REFERENCE_DIR` set (the reference job does this after `run.py emit`),
// the pair of files is exchanged and `run.py compare` checks both directions from the
// other side. Without it the two golden comparisons still run, so the differential is
// part of every `moon test`.

///|
/// A generated transcript as the lines it holds. The vectors are multi-line
/// literals, so `moon fmt` cannot reflow them; a trailing newline is not a line.
pub fn expected_lines(text : String) -> Array[String] {
  let parts = text.split("\n").map(fn(part) { part.to_owned() }).collect()
  if parts.length() > 0 && parts[parts.length() - 1] == "" {
    parts.truncate(parts.length() - 1)
  }
  parts
}

///|
pub fn reference_dir() -> String? {
  @env.get_env_var("MOONORM_REFERENCE_DIR")
}

///|
/// Run `f` against a fresh in-memory database, then close it.
pub fn[T] with_reference_db(
  f : (@session.Session) -> T raise @moondb.DbError,
) -> T raise @moondb.DbError {
  let driver = @sqlite.SqliteDriver::open(":memory:")
  let sess = @session.Session::new(driver)
  let value = f(sess)
  sess.close()
  value
}

///|
/// Open `path`, hand the session to `f`, and close it afterwards.
pub fn[T] with_reference_file(
  path : String,
  f : (@session.Session) -> T raise @moondb.DbError,
) -> T raise @moondb.DbError {
  let driver = @sqlite.SqliteDriver::open(path)
  let sess = @session.Session::new(driver)
  let value = f(sess)
  sess.close()
  value
}

///|
/// The schema this library builds for the two models, in the canonical lines the
/// reference writes: the tables, their columns with affinity and nullability, the
/// index, and the foreign key with the action it carries.
test "reference: the schema this builds is the schema SQLAlchemy declares" {
  let got = with_reference_db(fn(sess) raise @moondb.DbError {
    for statement in reference_ddl() {
      sess.execute(statement, []) |> ignore
    }
    reference_snapshot(sess)
  }) catch {
    e => abort("schema snapshot failed: " + e.to_string())
  }
  assert_eq(got, expected_lines(expected_reference_schema_text))
}

///|
/// The ten queries, on a database this library built from its own models.
test "reference: the ten queries answer what SQLAlchemy answers" {
  let got = with_reference_db(fn(sess) raise @moondb.DbError {
    reference_seed(sess)
    reference_transcript(sess)
  }) catch {
    e => abort("transcript failed: " + e.to_string())
  }
  assert_eq(got, expected_lines(expected_reference_transcript_text))
}

///|
/// The other direction: a database SQLAlchemy created, read by this library. The
/// schema has to look the same to our reflection, and the reads have to return the
/// rows SQLAlchemy stored.
test "reference: a database SQLAlchemy built reads the same here" {
  guard reference_dir() is Some(dir) else { return }
  let path = dir + "/sa.db"
  let got = with_reference_file(path, fn(sess) raise @moondb.DbError {
    (reference_snapshot(sess), reference_transcript(sess, reads_only=true))
  }) catch {
    e => abort("reading " + path + " failed: " + e.to_string())
  }
  assert_eq(got.0, expected_lines(expected_reference_schema_text))
  assert_eq(got.1, expected_lines(expected_reference_reads_text))
}

///|
/// The first direction: the library creates its tables in the file the reference
/// prepared, so `run.py compare` can open it with SQLAlchemy afterwards.
test "reference: the library leaves a database for SQLAlchemy to read" {
  guard reference_dir() is Some(dir) else { return }
  let path = dir + "/orm.db"
  let got = with_reference_file(path, fn(sess) raise @moondb.DbError {
    reference_seed(sess)
    (reference_transcript(sess), reference_snapshot(sess))
  }) catch {
    e => abort("building " + path + " failed: " + e.to_string())
  }
  assert_eq(got.0, expected_lines(expected_reference_transcript_text))
  assert_eq(got.1, expected_lines(expected_reference_schema_text))
}
