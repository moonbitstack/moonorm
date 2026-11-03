// The engine: a connection string names the backend, and the backend names the
// dialect a session renders its statements for. moonorm owns no drivers, so the
// engine parses the URL and hands the dialect to a session; the caller supplies the
// driver the scheme names (moonsqlite, moonpostgres, …).

///|
/// Why a connection string could not be read.
pub(all) suberror DsnError {
  DsnError(String)
}

///|
/// The human-readable form of a `DsnError`.
pub impl Show for DsnError with fn output(self : DsnError, logger : &Logger) -> Unit {
  let DsnError(m) = self
  logger.write_string("DsnError: " + m)
}

///|
pub extend DsnError with Show::{to_string, output}

///|
/// A parsed connection string. The scheme picks the driver and the `dialect`; the
/// rest is what a driver needs to connect. A `+driver` suffix (SQLAlchemy's
/// `postgresql+asyncpg://`) overrides `driver` while leaving the scheme's dialect.
pub(all) struct Dsn {
  // The URL scheme as written: "sqlite", "postgresql", "postgres" or "mysql".
  scheme : String
  // The driver the scheme (or its `+suffix`) names.
  driver : String
  dialect : @query.Dialect
  user : String?
  password : String?
  host : String?
  port : Int32?
  // The database name (PostgreSQL/MySQL) or file path (SQLite). `None` is an
  // in-memory SQLite database.
  database : String?
  // Query-string parameters, last value wins.
  params : Map[String, String]
}

///|
/// Parse `dsn` into a `Dsn`. It accepts the SQLAlchemy URL forms:
///
/// - `sqlite://`, `sqlite:///:memory:`, `sqlite:///file.db`, `sqlite:////abs/file.db`
/// - `postgresql://user:pass@host:5432/db?sslmode=require` (and `postgres://`)
/// - `mysql://user:pass@host:3306/db` (and `mysql+pymysql://`)
///
/// A `+driver` suffix overrides the driver name without changing the dialect.
/// An absent or unknown scheme raises `DsnError`.
pub fn parse_dsn(dsn : String) -> Dsn raise DsnError {
  let raw = dsn.trim(chars=" ").to_owned()
  if raw == "" {
    raise DsnError("empty connection string")
  }
  let (scheme_part, rest) = match index_of(raw, "://") {
    Some(i) => (slice(raw, 0, i), slice(raw, i + 3, raw.length()))
    None =>
      // SQLite also accepts the shorter `sqlite:` form (`sqlite::memory:`,
      // `sqlite:file.db`).
      if raw.has_prefix("sqlite:") {
        ("sqlite", slice(raw, "sqlite:".length(), raw.length()))
      } else {
        raise DsnError("connection string has no scheme: " + raw)
      }
  }
  let (scheme, driver) = match index_of(scheme_part, "+") {
    Some(i) =>
      (
        slice(scheme_part, 0, i),
        slice(scheme_part, i + 1, scheme_part.length()),
      )
    None => (scheme_part, scheme_part)
  }
  let dialect = match scheme {
    "sqlite" => @query.Sqlite
    "postgres" | "postgresql" => @query.Postgres
    "mysql" => @query.Mysql
    _ => raise DsnError("unknown scheme: " + scheme)
  }
  if scheme == "sqlite" {
    parse_sqlite(rest, scheme, driver, dialect)
  } else {
    parse_network(rest, scheme, driver, dialect)
  }
}

///|
/// A SQLite URL: the remainder is a file path (or empty / `:memory:` for an
/// in-memory database). SQLAlchemy's slash rule is kept: one leading `/` marks a
/// relative path (`sqlite:///file.db`), two an absolute one (`sqlite:////file.db`).
fn parse_sqlite(
  rest : String,
  scheme : String,
  driver : String,
  dialect : @query.Dialect,
) -> Dsn {
  let (path_part, query_part) = split_query(rest)
  let path = if path_part.has_prefix("/") {
    slice(path_part, 1, path_part.length())
  } else {
    path_part
  }
  let database = if path == "" || path == ":memory:" {
    None
  } else {
    Some(path)
  }
  {
    scheme,
    driver,
    dialect,
    user: None,
    password: None,
    host: None,
    port: None,
    database,
    params: parse_params(query_part),
  }
}

///|
/// A PostgreSQL or MySQL URL: `[userinfo@]host[:port][/database][?params]`.
fn parse_network(
  rest : String,
  scheme : String,
  driver : String,
  dialect : @query.Dialect,
) -> Dsn {
  let (authority, after) = match index_of(rest, "/") {
    Some(i) => (slice(rest, 0, i), slice(rest, i + 1, rest.length()))
    None => (rest, "")
  }
  let (database_part, query_part) = split_query(after)
  let (userinfo, hostport) = match index_of(authority, "@") {
    Some(i) =>
      (
        Some(slice(authority, 0, i)),
        slice(authority, i + 1, authority.length()),
      )
    None => (None, authority)
  }
  let (user, password) = match userinfo {
    Some(ui) =>
      match index_of(ui, ":") {
        Some(i) => (Some(slice(ui, 0, i)), Some(slice(ui, i + 1, ui.length())))
        None => (Some(ui), None)
      }
    None => (None, None)
  }
  let (host, port) = parse_hostport(hostport)
  let database = if database_part == "" { None } else { Some(database_part) }
  {
    scheme,
    driver,
    dialect,
    user,
    password,
    host,
    port,
    database,
    params: parse_params(query_part),
  }
}

///|
/// Split `s` at its first `?` into the part before and the query string after.
fn split_query(s : String) -> (String, String) {
  match index_of(s, "?") {
    Some(i) => (slice(s, 0, i), slice(s, i + 1, s.length()))
    None => (s, "")
  }
}

///|
/// `host[:port]`, with IPv6 bracketed as `[addr]` or `[addr]:port`.
fn parse_hostport(hp : String) -> (String?, Int32?) {
  if hp == "" {
    return (None, None)
  }
  if hp.has_prefix("[") {
    match index_of(hp, "]") {
      Some(j) => {
        let host = slice(hp, 1, j)
        let tail = slice(hp, j + 1, hp.length())
        if tail.has_prefix(":") {
          (Some(host), parse_port(slice(tail, 1, tail.length())))
        } else {
          (Some(host), None)
        }
      }
      None => (Some(hp), None)
    }
  } else {
    match index_of(hp, ":") {
      Some(i) =>
        (Some(slice(hp, 0, i)), parse_port(slice(hp, i + 1, hp.length())))
      None => (Some(hp), None)
    }
  }
}

///|
/// A decimal port, or `None` when `s` is not all digits.
fn parse_port(s : String) -> Int32? {
  if s.length() == 0 {
    return None
  }
  let mut n = 0
  let mut i = 0
  while i < s.length() {
    let c = s[i].to_int()
    if c < 48 || c > 57 {
      return None
    }
    n = n * 10 + (c - 48)
    i = i + 1
  }
  Some(n)
}

///|
/// The `k=v&k2=v2` query string as a map, last value winning. A bare key maps to
/// the empty string.
fn parse_params(query : String) -> Map[String, String] {
  let params : Map[String, String] = Map([])
  if query == "" {
    return params
  }
  for part in query.split("&") {
    let pair = part.to_owned()
    if pair != "" {
      match index_of(pair, "=") {
        Some(i) =>
          params.set(slice(pair, 0, i), slice(pair, i + 1, pair.length()))
        None => params.set(pair, "")
      }
    }
  }
  params
}

///|
/// The byte offset of `needle` in `s`, or `None`. An empty needle matches at 0.
fn index_of(s : String, needle : String) -> Int32? {
  let n = s.length()
  let m = needle.length()
  if m == 0 {
    return Some(0)
  }
  let mut i = 0
  while i + m <= n {
    let mut j = 0
    let mut ok = true
    while j < m {
      if s[i + j] != needle[j] {
        ok = false
        break
      }
      j = j + 1
    }
    if ok {
      return Some(i)
    }
    i = i + 1
  }
  None
}

///|
/// The substring `s[start..end]`, empty when the range is empty.
fn slice(s : String, start : Int32, end : Int32) -> String {
  if start >= end {
    ""
  } else {
    s.exact_view(start~, end~).to_owned()
  }
}

///|
/// A backend selected by its connection string: the parsed `Dsn` plus the dialect
/// its sessions render for. `session` binds one to a driver the caller supplies.
pub struct Engine {
  dsn : Dsn
}

///|
/// Parse `dsn` into an `Engine`. The URL's scheme picks the driver and the dialect.
pub fn Engine::new(dsn : String) -> Engine raise DsnError {
  { dsn: parse_dsn(dsn), }
}

///|
/// An `Engine` over an already parsed `Dsn`.
pub fn Engine::from_dsn(dsn : Dsn) -> Engine {
  { dsn, }
}

///|
/// The parsed connection string.
pub fn Engine::dsn(self : Engine) -> Dsn {
  self.dsn
}

///|
/// The dialect the URL's scheme selects.
pub fn Engine::dialect(self : Engine) -> @query.Dialect {
  self.dsn.dialect
}

///|
/// The driver the URL names (the scheme, or its `+driver` override).
pub fn Engine::driver(self : Engine) -> String {
  self.dsn.driver
}

///|
/// Wrap `driver` in a session that renders for this engine's dialect. moonorm owns
/// no driver contract, so the concrete backend is the caller's to supply.
pub fn Engine::session(
  self : Engine,
  driver : &@moondb.Driver,
) -> @session.Session {
  @session.Session::new(driver, dialect=self.dsn.dialect)
}
