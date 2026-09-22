// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The async PostgreSQL connection — the driver itself. Every network round trip
// is async (MoonBit sockets are async-only), so this is the asyncpg-shaped core;
// the @moondb.AsyncDriver conformance in driver.mbt delegates straight to it.

///|
/// A live connection to a PostgreSQL backend, already past the startup
/// handshake and sitting at `ReadyForQuery`. Runs the v3 frontend/backend
/// protocol over a single `@socket.Tcp`. Not safe for concurrent use by
/// multiple tasks: one statement must complete (drain to `ReadyForQuery`)
/// before the next begins, as the wire protocol is a strict request/response
/// pipeline per connection.
pub struct PgConn {
  tcp : @socket.Tcp
  mut closed : Bool
  // Set while a `PgRowStream` is outstanding. The wire is a strict per-connection
  // pipeline, so a new statement issued before the stream is drained/closed would
  // read the old result's leftover packets and desync the connection; guarding on
  // this turns that silent corruption into a clear error.
  mut streaming : Bool
}

///|
/// Open a connection and complete the startup handshake: send StartupMessage,
/// satisfy the authentication request (trust/`AuthenticationOk`, cleartext, MD5,
/// or SASL/SCRAM-SHA-256), and drain server parameters up to the first
/// `ReadyForQuery`. `host` may
/// be a hostname or a literal IP; `port` is typically 5432. Raises
/// `ConnectError` on any transport or handshake failure, including an
/// unsupported auth method.
pub async fn PgConn::connect(
  host : String,
  port : Int,
  user : String,
  password : String,
  database : String,
) -> PgConn raise DbError {
  let addr = @socket.Addr::resolve(host, port~) catch {
    e => raise @moondb.ConnectError("resolve \{host}: \{e}")
  }
  let tcp = @socket.Tcp::connect(addr) catch {
    e => raise @moondb.ConnectError("connect \{host}:\{port}: \{e}")
  }
  let conn = PgConn::{ tcp, closed: false, streaming: false, }
  // Close the socket on any handshake failure (a bad-password ErrorResponse is the
  // common case) — MoonBit has no fd finalizer, so a raise here would leak it.
  errdefer conn.tcp.close()
  conn.write_all(build_startup(user, database))
  conn.run_startup(user, password)
  conn
}

///|
async fn PgConn::write_all(self : PgConn, bytes : Bytes) -> Unit raise DbError {
  (self.tcp : &@io.Writer).write(bytes) catch {
    e => raise @moondb.ConnectError("write: \{e}")
  }
}

///|
/// Read one framed backend message: 1-byte tag, Int32 self-inclusive length,
/// then the payload. Returns the tag as an `Int` and the payload bytes.
async fn PgConn::read_message(self : PgConn) -> (Int, Bytes) raise DbError {
  let head = (self.tcp : &@io.Reader).read_exactly(5) catch {
    e => raise @moondb.ConnectError("read header: \{e}")
  }
  if head.length() < 5 {
    raise @moondb.ConnectError("connection closed mid-message")
  }
  let tag = head[0].to_int()
  guard @fixed.read_i32(head[:], at=1) is Some(len) else {
    raise @moondb.QueryError("protocol: truncated message header")
  }
  let body_len = len - 4
  if body_len < 0 {
    raise @moondb.QueryError("protocol: negative message length")
  }
  let payload = if body_len == 0 {
    b""
  } else {
    (self.tcp : &@io.Reader).read_exactly(body_len) catch {
      e => raise @moondb.ConnectError("read body: \{e}")
    }
  }
  (tag, payload)
}

///|
/// Drive the authentication + parameter phase until the first `ReadyForQuery`.
async fn PgConn::run_startup(
  self : PgConn,
  user : String,
  password : String,
) -> Unit raise DbError {
  for ;; {
    let (tag, payload) = self.read_message()
    match tag {
      // 'R' Authentication
      82 => {
        let r = ByteReader::new(payload)
        let auth = r.i32()
        match auth {
          0 => () // AuthenticationOk — await ReadyForQuery
          3 => self.write_all(build_password(password)) // cleartext
          5 => {
            let salt = r.take(4)
            self.write_all(
              build_password(pg_md5_password(user, password, salt)),
            )
          }
          10 => self.run_sasl(password, r)
          other =>
            raise @moondb.ConnectError(
              "unsupported authentication request \{other}",
            )
        }
      }
      // 'E' ErrorResponse
      69 => raise @moondb.ConnectError(parse_error_response(payload))
      // 'Z' ReadyForQuery
      90 => return
      // 'S' ParameterStatus / 'K' BackendKeyData / 'N' NoticeResponse — ignore
      _ => ()
    }
  }
}

///|
/// SCRAM-SHA-256 SASL exchange (RFC 5802/7677 + PG protocol §55.3), entered from
/// an AuthenticationSASL message whose offered-mechanism list is read from `mechs`.
/// Sends the client-first message with a CSPRNG nonce, derives the client-final
/// proof from the server's challenge, and verifies the server signature before
/// returning; the caller's loop then consumes AuthenticationOk. The password is used
/// verbatim: SASLprep (RFC 4013) is not applied, so it must already be normalised —
/// an ASCII password needs nothing, but a non-ASCII one must be pre-normalised or
/// the derived key will not match the server's stored verifier.
async fn PgConn::run_sasl(
  self : PgConn,
  password : String,
  mechs : ByteReader,
) -> Unit raise DbError {
  let mut scram = false
  for ;; {
    let m = mechs.cstring()
    if m == "" {
      break
    }
    if m == "SCRAM-SHA-256" {
      scram = true
    }
  }
  guard scram else {
    raise @moondb.ConnectError("server offers no SCRAM-SHA-256 SASL mechanism")
  }
  let entropy = match @env.rand(18) {
    Some(b) => b
    None => raise @moondb.ConnectError("no CSPRNG for the SCRAM client nonce")
  }
  let client_first_bare = "n=,r=" + @base64.encode(entropy)
  self.write_all(build_sasl_initial("SCRAM-SHA-256", "n,," + client_first_bare))
  let server_first = self.read_sasl_message(11)
  let (client_final, want_sig) = scram_client_final(
    @utf8.encode(password),
    client_first_bare,
    server_first,
  )
  self.write_all(build_sasl_response(client_final))
  let server_final = self.read_sasl_message(12)
  guard server_final == "v=" + @base64.encode(want_sig) else {
    raise @moondb.ConnectError("SCRAM server signature mismatch")
  }
}

///|
/// Read the next backend message, require Authentication ('R') with SASL status
/// `want` (11 = SASLContinue, 12 = SASLFinal), and return its trailing bytes as
/// text — the server-first or server-final SCRAM message.
async fn PgConn::read_sasl_message(
  self : PgConn,
  want : Int,
) -> String raise DbError {
  let (tag, payload) = self.read_message()
  if tag == 69 {
    raise @moondb.ConnectError(parse_error_response(payload))
  }
  guard tag == 82 else {
    raise @moondb.ConnectError("protocol: expected Authentication during SASL")
  }
  let r = ByteReader::new(payload)
  guard r.i32() == want else {
    raise @moondb.ConnectError("protocol: unexpected SASL authentication code")
  }
  utf8_decode(r.take(payload.length() - 4))
}

///|
/// The accumulated result of one statement: the rows it returned (empty for
/// DDL/DML) plus the CommandComplete tag string.
priv struct QueryOutcome {
  rows : Array[Row]
  command_tag : String
}

///|
/// Read backend messages after a query has been sent, materialising every
/// DataRow against the latest RowDescription, until `ReadyForQuery`.
async fn PgConn::read_results(self : PgConn) -> QueryOutcome raise DbError {
  let rows : Array[Row] = []
  let mut col_names : Array[String] = []
  let mut col_oids : Array[Int] = []
  let mut command_tag = ""
  for ;; {
    let (tag, payload) = self.read_message()
    match tag {
      // 'T' RowDescription. A malformed one has to drain like an error does: the
      // rest of this result is still on the socket, and leaving it there means the
      // next statement reads it.
      84 => {
        errdefer self.drain_until_ready()
        let (names, oids) = parse_row_description(payload)
        col_names = names
        col_oids = oids
      }
      // 'D' DataRow
      68 => {
        errdefer self.drain_until_ready()
        rows.push(parse_data_row(payload, col_names, col_oids))
      }
      // 'C' CommandComplete
      67 => {
        let r = ByteReader::new(payload)
        command_tag = r.cstring()
      }
      // 'E' ErrorResponse
      69 => {
        // still drain to ReadyForQuery so the connection stays usable
        let msg = parse_error_response(payload)
        self.drain_until_ready()
        raise @moondb.QueryError(msg)
      }
      // 'Z' ReadyForQuery
      90 => return QueryOutcome::{ rows, command_tag, }
      // 'G' CopyInResponse: the server is now waiting for us to send copy data.
      // Reading on would block forever with nothing to read, so say so instead of
      // hanging. 'H' CopyOutResponse is the mirror: the rows are copy data this
      // driver cannot deliver, so reporting zero rows would be a lie.
      71 | 72 =>
        raise @moondb.QueryError(
          "protocol: COPY is not supported by this driver",
        )
      // '1' ParseComplete / '2' BindComplete / 'n' NoData / 't' ParamDesc /
      // 'I' EmptyQueryResponse / 'S' ParameterStatus / 'N' NoticeResponse
      _ => ()
    }
  }
}

///|
/// Decode a RowDescription ('T') payload into column names and their field type
/// OIDs (index-aligned). Only the name and type OID drive decoding; the other
/// per-field attributes (table OID, attribute number, type size/modifier, format
/// code) are read to advance the cursor.
fn parse_row_description(
  payload : Bytes,
) -> (Array[String], Array[Int]) raise DbError {
  let r = ByteReader::new(payload)
  let count = r.i16()
  let names : Array[String] = []
  let oids : Array[Int] = []
  for _i in 0..<count {
    names.push(r.cstring())
    r.i32() |> ignore // table OID
    r.i16() |> ignore // column attribute number
    oids.push(r.i32()) // field type OID
    r.i16() |> ignore // type size
    r.i32() |> ignore // type modifier
    r.i16() |> ignore // format code
  }
  (names, oids)
}

///|
/// Decode a DataRow ('D') payload against the current column names/OIDs into a
/// [`Row`]. Each cell is a length-prefixed text value (length `-1` ⇒ `NULL`),
/// decoded by [`decode_value`] using its column's type OID.
fn parse_data_row(
  payload : Bytes,
  col_names : Array[String],
  col_oids : Array[Int],
) -> Row raise DbError {
  let r = ByteReader::new(payload)
  let count = r.i16()
  let values : Array[Value] = []
  for i in 0..<count {
    let cell_len = r.i32()
    if cell_len < 0 {
      values.push(@moondb.Null)
    } else {
      let raw = utf8_decode(r.take(cell_len))
      let oid = if i < col_oids.length() { col_oids[i] } else { 0 }
      values.push(decode_value(oid, false, raw))
    }
  }
  @moondb.Row::{ columns: col_names, values, }
}

///|
/// After an ErrorResponse, consume messages until `ReadyForQuery` so the next
/// statement starts from a clean protocol state.
async fn PgConn::drain_until_ready(self : PgConn) -> Unit raise DbError {
  for ;; {
    let (tag, _payload) = self.read_message()
    if tag == 90 {
      return
    }
  }
}

///|
/// Run a row-returning statement and materialise every row. Uses the simple
/// Query protocol when `params` is empty, and the extended Parse/Bind/Execute
/// protocol (with `?`→`$n` translation and out-of-band text-format binding)
/// when parameters are supplied.
pub async fn PgConn::query(
  self : PgConn,
  sql : String,
  params : Array[Value],
) -> Array[Row] raise DbError {
  self.run_statement(sql, params).rows
}

///|
/// Run a non-row statement (INSERT/UPDATE/DELETE/DDL) and report rows changed.
/// `last_insert_id` is `0`: the simple/extended protocols do not surface a
/// generated key without a `RETURNING` clause (roadmap).
pub async fn PgConn::execute(
  self : PgConn,
  sql : String,
  params : Array[Value],
) -> ExecResult raise DbError {
  let outcome = self.run_statement(sql, params)
  @moondb.ExecResult::{
    rows_affected: command_tag_rows(outcome.command_tag),
    last_insert_id: 0,
  }
}

///|
/// Send a statement on the wire: the simple Query protocol when `params` is empty,
/// otherwise the extended Parse/Bind/Describe/Execute/Sync batch (with `?`→`$n`
/// translation and out-of-band text binding). The response is left on the socket
/// for [`read_results`] or a [`PgRowStream`] to consume.
async fn PgConn::send_statement(
  self : PgConn,
  sql : String,
  params : Array[Value],
) -> Unit raise DbError {
  if self.closed {
    raise @moondb.Closed
  }
  if self.streaming {
    raise @moondb.QueryError(
      "a query stream is still open on this connection; drain it or call close() before the next statement",
    )
  }
  if params.length() == 0 {
    self.write_all(build_query(sql))
  } else {
    let translated = translate_placeholders(sql)
    let batch = concat_bytes(
      concat_bytes(
        concat_bytes(build_parse(translated), build_bind(params)),
        concat_bytes(build_describe_portal(), build_execute()),
      ),
      build_sync(),
    )
    self.write_all(batch)
  }
}

///|
async fn PgConn::run_statement(
  self : PgConn,
  sql : String,
  params : Array[Value],
) -> QueryOutcome raise DbError {
  self.send_statement(sql, params)
  self.read_results()
}

///|
/// A forward-only cursor that reads a query's rows off the wire on demand instead
/// of buffering them — the streaming counterpart to [`query`], for results too
/// large to materialise (asyncpg's cursor, SQLAlchemy's `stream_results`). It is
/// bound to its `PgConn`, which is a single-statement pipeline: the stream must be
/// drained (`next` returns `None`) or [`close`d](PgRowStream::close) before another
/// statement runs on that connection.
pub struct PgRowStream {
  conn : PgConn
  mut col_names : Array[String]
  mut col_oids : Array[Int]
  mut done : Bool
}

///|
/// Send `sql` (with bound `params`) and return a streaming cursor over its rows.
pub async fn PgConn::query_stream(
  self : PgConn,
  sql : String,
  params : Array[Value],
) -> PgRowStream raise DbError {
  self.send_statement(sql, params)
  self.streaming = true
  { conn: self, col_names: [], col_oids: [], done: false, }
}

///|
/// The next row, or `None` once the result is exhausted. Reads messages until a
/// `DataRow` (updating the column metadata from any `RowDescription` first), and on
/// `ReadyForQuery` marks the stream done. An `ErrorResponse` is drained to
/// ReadyForQuery before raising, so the connection stays usable.
pub async fn PgRowStream::next(self : PgRowStream) -> Row? raise DbError {
  if self.done {
    return None
  }
  for ;; {
    let (tag, payload) = self.conn.read_message()
    match tag {
      // 'T' RowDescription. A malformed one leaves the rest of the result on the
      // socket with the stream still marked live, which bricks the connection —
      // drain and close the stream before raising, as the error path does.
      84 => {
        errdefer {
          self.conn.drain_until_ready()
          self.finish()
        }
        let (names, oids) = parse_row_description(payload)
        self.col_names = names
        self.col_oids = oids
      }
      // 'D' DataRow
      68 => {
        errdefer {
          self.conn.drain_until_ready()
          self.finish()
        }
        return Some(parse_data_row(payload, self.col_names, self.col_oids))
      }
      // 'E' ErrorResponse
      69 => {
        let msg = parse_error_response(payload)
        self.conn.drain_until_ready()
        self.finish()
        raise @moondb.QueryError(msg)
      }
      // 'Z' ReadyForQuery
      90 => {
        self.finish()
        return None
      }
      // 'C' CommandComplete / 'S' ParameterStatus / others — keep reading
      _ => ()
    }
  }
}

///|
/// Mark the stream done and release the connection's streaming guard so the next
/// statement can run.
fn PgRowStream::finish(self : PgRowStream) -> Unit {
  self.done = true
  self.conn.streaming = false
}

///|
/// Abandon the stream early, draining any unread response to ReadyForQuery so the
/// connection can run the next statement. Idempotent once the stream is done.
pub async fn PgRowStream::close(self : PgRowStream) -> Unit raise DbError {
  if !self.done {
    self.conn.drain_until_ready()
    self.finish()
  }
}

///|
/// Begin an explicit transaction (`BEGIN`).
pub async fn PgConn::begin(self : PgConn) -> Unit raise DbError {
  self.run_statement("BEGIN", []) |> ignore
}

///|
/// Commit the current transaction (`COMMIT`).
pub async fn PgConn::commit(self : PgConn) -> Unit raise DbError {
  self.run_statement("COMMIT", []) |> ignore
}

///|
/// Roll back the current transaction (`ROLLBACK`).
pub async fn PgConn::rollback(self : PgConn) -> Unit raise DbError {
  self.run_statement("ROLLBACK", []) |> ignore
}

///|
/// Close the connection: best-effort Terminate, then close the socket.
/// Idempotent — a second call is a no-op.
pub async fn PgConn::close(self : PgConn) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  // Best-effort Terminate, protected from cancellation so a shutting-down task
  // still sends it before the socket is dropped.
  @async.protect_from_cancel(() => {
    (self.tcp : &@io.Writer).write(build_terminate()) catch {
      _ => ()
    }
  })
  self.tcp.close()
}

///|
/// Parse an ErrorResponse payload into a human-readable message, preferring the
/// `M` (message) field and prefixing the `S`/`C` severity/code when present.
fn parse_error_response(payload : Bytes) -> String {
  let r = ByteReader::new(payload)
  let mut severity = ""
  let mut code = ""
  let mut message = ""
  for ;; {
    let field = r.u8() catch { _ => 0 }
    if field == 0 {
      break
    }
    let value = r.cstring() catch { _ => "" }
    match field {
      83 => severity = value // 'S'
      67 => code = value // 'C'
      77 => message = value // 'M'
      _ => ()
    }
  }
  let prefix = if severity != "" && code != "" {
    severity + " " + code + ": "
  } else {
    ""
  }
  prefix + message
}

///|
/// The trailing count in a CommandComplete tag (`INSERT 0 5` → 5, `UPDATE 3` →
/// 3, `SELECT 4` → 4, `CREATE TABLE` → 0) as `rows_affected`.
fn command_tag_rows(tag : String) -> Int64 {
  let mut last_start = 0
  for i in 0..<tag.length() {
    if tag[i] == ' ' {
      last_start = i + 1
    }
  }
  let last = tag[last_start:tag.length()].to_owned()
  match parse_int64(last) {
    Some(n) => n
    None => 0
  }
}

///|
pub extend PgConn with @moondb.AsyncDriver::{ping}
