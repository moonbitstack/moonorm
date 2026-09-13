// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A live MySQL connection over a raw TCP socket, speaking the wire protocol in
/// pure MoonBit. This is the asynchronous, full-fidelity driver: it owns the
/// socket for its whole lifetime, so `begin`/`commit`/`rollback` bracket a real
/// server-side transaction. The synchronous `@moondb.Driver` adapter
/// ([`MysqlDriver`]) is layered on top for the moondb contract.
///
/// Framing is the classic 3-byte little-endian length + 1-byte sequence id
/// header; the transport transparently reassembles the `0xFFFFFF` continuation
/// frames a large payload is split into.
pub struct MysqlConn {
  tcp : @socket.Tcp
  mut seq : Int
  mut closed : Bool
  mut server_kind : @moonmysql.ServerKind
  // Set while a `MysqlRowStream` is outstanding — the wire is a per-connection
  // pipeline, so issuing a command before the stream drains would read the old
  // result's leftover packets and desync the connection.
  mut streaming : Bool
  // How this server reads a string literal. Asked for at connect time rather than
  // assumed: under NO_BACKSLASH_ESCAPES a backslash-escaping writer leaves a
  // value's own quote live, which is an injection.
  mut quote_mode : @moonmysql.QuoteMode
}

///|
/// The dialect (MySQL or MariaDB) reported by the server's handshake.
pub fn MysqlConn::server_kind(self : MysqlConn) -> @moonmysql.ServerKind {
  self.server_kind
}

///|
/// Read one logical packet payload, reassembling `0xFFFFFF`-length continuation
/// frames. Updates the connection's last-seen sequence id.
async fn MysqlConn::read_packet(self : MysqlConn) -> Bytes {
  let out = Buffer()
  for ;; {
    let hdr = self.tcp.read_exactly(4)
    let len = hdr[0].to_int() | (hdr[1].to_int() << 8) | (hdr[2].to_int() << 16)
    self.seq = hdr[3].to_int()
    if len > 0 {
      out.write_bytes(self.tcp.read_exactly(len)[:])
    }
    if len < 0xFFFFFF {
      break
    }
  }
  out.to_bytes()
}

///|
/// Write one packet: the header (payload length + `seq`) then the payload.
///
/// The length field is three bytes, so a payload of 2^24-1 or more goes out as
/// several packets with the sequence id advancing, and a payload that is an exact
/// multiple of the limit needs a trailing empty packet to say it has ended. Without
/// the split the length silently wraps and the server reads the tail of the payload
/// as the next packet header. Reachable in practice: a blob is hex-expanded to twice
/// its size on the way out, so an 8 MB value crosses the boundary.
async fn MysqlConn::write_packet(
  self : MysqlConn,
  seq : Int,
  payload : Bytes,
) -> Unit {
  let limit = 0xFFFFFF
  if payload.length() >= limit {
    let mut off = 0
    let mut s = seq
    while off < payload.length() {
      let end = if off + limit < payload.length() {
        off + limit
      } else {
        payload.length()
      }
      self.write_one_packet(s, payload[off:end].to_owned())
      s = (s + 1) & 0xFF
      off = end
    }
    if payload.length() % limit == 0 {
      self.write_one_packet(s, b"")
    }
    return
  }
  self.write_one_packet(seq, payload)
}

///|
/// One wire packet, whose payload is already known to fit the three-byte length.
async fn MysqlConn::write_one_packet(
  self : MysqlConn,
  seq : Int,
  payload : Bytes,
) -> Unit {
  let buf = Buffer()
  let n = payload.length()
  buf.write_byte((n & 0xFF).to_byte())
  buf.write_byte(((n >> 8) & 0xFF).to_byte())
  buf.write_byte(((n >> 16) & 0xFF).to_byte())
  buf.write_byte((seq & 0xFF).to_byte())
  buf.write_bytes(payload[:])
  self.tcp.write(buf.to_bytes())
}

///|
/// Open a connection to `host:port` and complete the auth handshake against
/// `user`/`password`, selecting `database` (empty for none). Works against both
/// MySQL and MariaDB (the reported dialect is on [`server_kind`]).
///
/// mysql_native_password and caching_sha2_password (MySQL 8's default, including
/// the RSA full-auth path on a cache miss) are handled directly, whether the
/// server drives them from its default or via an AuthSwitchRequest. A switch to any
/// other plugin (e.g. client_ed25519, on the README roadmap) raises
/// [`@moonmysql.MysqlError::UnsupportedError`].
pub async fn MysqlConn::connect(
  host : String,
  port : Int,
  user : String,
  password : String,
  database : String,
) -> MysqlConn {
  let addr = @socket.Addr::resolve(host, port~)
  let tcp = @socket.Tcp::connect(addr)
  let conn = MysqlConn::{
    tcp,
    seq: 0,
    closed: false,
    server_kind: @moonmysql.ServerKind::MySQL,
    streaming: false,
    quote_mode: @moonmysql.QuoteMode::Backslash,
  }
  let pw = @utf8.encode(password[:])
  // Close the socket on any handshake failure — a bad-credentials ERR is the
  // common case, and MoonBit has no fd finalizer to reclaim a leaked socket.
  errdefer conn.tcp.close()
  conn.do_handshake(user, pw, database)
  conn.learn_quoting()
  conn
}

///|
/// Ask the server how it reads string literals and what the connection charset is,
/// and refuse the connection when the pair is one this driver cannot escape safely.
///
/// The text protocol renders parameters as literals, so the escaping has to match
/// the server's actual `sql_mode` — assuming backslashes are escapes when they are
/// not is an injection, not a formatting difference. And in a charset where a
/// multibyte character can end in `0x5C`, backslash escaping is unsafe no matter
/// what: the quote that follows becomes the tail of a legitimate character. That
/// combination is refused rather than served insecurely.
async fn MysqlConn::learn_quoting(self : MysqlConn) -> Unit {
  let rows = self.query("SELECT @@sql_mode, @@character_set_connection", [])
  guard rows.length() > 0 else { return }
  let mode_text = match rows[0].values[0] {
    Text(t) => t
    _ => ""
  }
  let charset = match rows[0].values[1] {
    Text(t) => t
    _ => ""
  }
  if mode_text.contains("NO_BACKSLASH_ESCAPES") {
    self.quote_mode = @moonmysql.QuoteMode::DoubleQuote
    return
  }
  // The charsets whose trailing bytes can be 0x5C. Doubling a quote is safe in all
  // of them; escaping with a backslash is not.
  for unsafe_cs in ["gbk", "big5", "sjis", "cp932", "gb18030"] {
    if charset == unsafe_cs {
      raise @moonmysql.ProtocolError(
        "connection charset '" +
        charset +
        "' cannot be escaped safely without NO_BACKSLASH_ESCAPES or prepared statements",
      )
    }
  }
}

///|
/// The authentication exchange, run under [`connect`]'s close-on-error guard.
async fn MysqlConn::do_handshake(
  self : MysqlConn,
  user : String,
  pw : Bytes,
  database : String,
) -> Unit {
  let handshake = @moonmysql.parse_handshake(self.read_packet())
  self.server_kind = handshake.server_kind
  let response = @moonmysql.build_handshake_response(
    handshake, user, pw, database,
  )
  // The handshake response is sequence id 1 (the server's handshake was 0).
  self.write_packet(self.seq + 1, response)
  let auth = self.read_packet()
  if @moonmysql.is_err_packet(auth) {
    raise @moonmysql.parse_err(auth)
  }
  if @moonmysql.is_ok_packet(auth) {
    return
  }
  // AuthSwitchRequest (0xFE + body): the server offers a different plugin — answer
  // mysql_native_password directly, or caching_sha2_password / client_ed25519 via
  // their scramble + AuthMoreData exchange.
  if @moonmysql.is_auth_switch_request(auth) {
    let (plugin, new_salt) = @moonmysql.parse_auth_switch_request(auth)
    if plugin == "mysql_native_password" || plugin == "" {
      self.write_packet(
        self.seq + 1,
        @moonmysql.native_password_scramble(pw, new_salt),
      )
      expect_ok_or_err(self.read_packet())
      return
    }
    if plugin == "caching_sha2_password" {
      self.write_packet(
        self.seq + 1,
        @moonmysql.caching_sha2_scramble(pw, new_salt),
      )
      self.finish_caching_sha2(pw, new_salt, self.read_packet())
      return
    }
    if plugin == "client_ed25519" {
      // MariaDB signs the raw 32-byte nonce (not the NUL-stripped salt) with the
      // password-keyed Ed25519 secret.
      let nonce = @moonmysql.parse_ed25519_challenge(auth)
      self.write_packet(
        self.seq + 1,
        @moonmysql.mariadb_ed25519_response(pw, nonce),
      )
      expect_ok_or_err(self.read_packet())
      return
    }
    raise @moonmysql.UnsupportedError(
      "server requested auth-switch to '" +
      plugin +
      "'; only mysql_native_password, caching_sha2_password and client_ed25519 are implemented",
    )
  }
  // AuthMoreData (lead byte 0x01): the caching_sha2 reply to the fast scramble we
  // already sent in the handshake response.
  if auth.length() >= 1 && auth[0].to_int() == 0x01 {
    self.finish_caching_sha2(pw, handshake.salt, auth)
    return
  }
  raise @moonmysql.UnsupportedError("unexpected packet during authentication")
}

///|
/// Drive the caching_sha2_password exchange to completion given the server's
/// AuthMoreData reply to the fast scramble. `0x03` is fast-auth success (a cached
/// digest); `0x04` needs full auth — without TLS the client fetches the server's
/// RSA public key and returns the nonce-obfuscated password RSA-OAEP encrypted
/// under it. `nonce` is the same salt the fast scramble used.
async fn MysqlConn::finish_caching_sha2(
  self : MysqlConn,
  pw : Bytes,
  nonce : Bytes,
  more_data : Bytes,
) -> Unit {
  guard more_data.length() >= 2 && more_data[0].to_int() == 0x01 else {
    raise @moonmysql.ProtocolError("caching_sha2: expected AuthMoreData")
  }
  match more_data[1].to_int() {
    0x03 => expect_ok_or_err(self.read_packet()) // fast auth success
    0x04 => {
      // Request the server's RSA public key (no TLS ⇒ full auth over RSA).
      self.write_packet(self.seq + 1, b"\x02")
      let key_pkt = self.read_packet()
      guard key_pkt.length() >= 1 && key_pkt[0].to_int() == 0x01 else {
        raise @moonmysql.ProtocolError("caching_sha2: expected public key")
      }
      let pem = @moonmysql.bytes_to_string(key_pkt[1:].to_owned())
      let seed = match @env.rand(20) {
        Some(b) => b
        None => raise @moonmysql.ProtocolError("no CSPRNG for the OAEP seed")
      }
      let token = @moonmysql.caching_sha2_full_auth_token(pw, nonce, pem, seed)
      self.write_packet(self.seq + 1, token)
      expect_ok_or_err(self.read_packet())
    }
    other =>
      raise @moonmysql.ProtocolError(
        "caching_sha2: unexpected status " + other.to_string(),
      )
  }
}

///|
/// A terminal auth packet must be OK (success) or ERR (raise); anything else is a
/// protocol violation.
fn expect_ok_or_err(pkt : Bytes) -> Unit raise @moonmysql.MysqlError {
  if @moonmysql.is_err_packet(pkt) {
    raise @moonmysql.parse_err(pkt)
  }
  if @moonmysql.is_ok_packet(pkt) {
    return
  }
  raise @moonmysql.ProtocolError("unexpected packet after auth")
}

///|
/// The outcome of one command: either an OK (no result set) or a materialised
/// text result set (column definitions plus raw row packets).
priv enum Outcome {
  Exec(@moonmysql.OkPacket)
  Rows(Array[@moonmysql.ColumnDef], Array[Bytes])
}

///|
/// Send a `COM_QUERY` carrying `query_bytes` and drive the text-protocol
/// response state machine to completion.
async fn MysqlConn::command(self : MysqlConn, query_bytes : Bytes) -> Outcome {
  if self.closed {
    raise @moondb.Closed
  }
  if self.streaming {
    raise @moonmysql.ProtocolError(
      "a query stream is still open on this connection; drain it or call close() before the next command",
    )
  }
  let payload = Buffer()
  payload.write_byte(b'\x03') // COM_QUERY
  payload.write_bytes(query_bytes[:])
  // A fresh command always starts at sequence id 0.
  self.write_packet(0, payload.to_bytes())
  let first = self.read_packet()
  if @moonmysql.is_err_packet(first) {
    raise @moonmysql.parse_err(first)
  }
  if @moonmysql.is_ok_packet(first) {
    return Exec(@moonmysql.parse_ok(first))
  }
  if first.length() > 0 && first[0].to_int() == 0xFB {
    raise @moonmysql.UnsupportedError("LOCAL INFILE is not supported")
  }
  let reader = @moonmysql.PacketReader::new(first)
  let column_count = reader.lenenc_uint().to_int()
  let columns : Array[@moonmysql.ColumnDef] = []
  for _ in 0..<column_count {
    columns.push(@moonmysql.parse_column_def(self.read_packet()))
  }
  // CLIENT_DEPRECATE_EOF is not negotiated, so an EOF closes the column block.
  let after_columns = self.read_packet()
  if @moonmysql.is_err_packet(after_columns) {
    raise @moonmysql.parse_err(after_columns)
  }
  let rows : Array[Bytes] = []
  // If the column-terminator was itself a row (defensive), keep it.
  if !@moonmysql.is_eof_packet(after_columns) {
    rows.push(after_columns)
  }
  for ;; {
    let p = self.read_packet()
    if @moonmysql.is_err_packet(p) {
      raise @moonmysql.parse_err(p)
    }
    if @moonmysql.is_eof_packet(p) {
      break
    }
    rows.push(p)
  }
  Rows(columns, rows)
}

///|
/// Run a non-row statement (`params` bound as escaped literals) and report the
/// rows affected and last insert id.
pub async fn MysqlConn::execute(
  self : MysqlConn,
  sql : String,
  params : Array[@moondb.Value],
) -> @moondb.ExecResult {
  match
    self.command(@moonmysql.bind_params(sql, params, mode=self.quote_mode)) {
    Exec(ok) =>
      @moondb.ExecResult::{
        rows_affected: ok.affected_rows,
        last_insert_id: ok.last_insert_id,
      }
    Rows(_, _) =>
      raise @moonmysql.ProtocolError(
        "execute() was given a row-returning statement; use query()",
      )
  }
}

///|
/// Run a row-returning statement and materialise every [`@moondb.Row`].
pub async fn MysqlConn::query(
  self : MysqlConn,
  sql : String,
  params : Array[@moondb.Value],
) -> Array[@moondb.Row] {
  match
    self.command(@moonmysql.bind_params(sql, params, mode=self.quote_mode)) {
    Rows(columns, row_payloads) =>
      @moonmysql.build_text_rows(columns, row_payloads)
    Exec(_) => []
  }
}

///|
/// A forward-only cursor that reads a query's rows off the wire on demand instead
/// of buffering them — the streaming counterpart to [`query`], for results too
/// large to materialise at once (`mysql_use_result`, SQLAlchemy's
/// `stream_results`). Bound to its `MysqlConn`, a single-command pipeline: the
/// stream must be drained (`next` returns `None`) or [`close`d](MysqlRowStream::close)
/// before another statement runs on that connection.
pub struct MysqlRowStream {
  conn : MysqlConn
  columns : Array[@moonmysql.ColumnDef]
  mut pending : Bytes?
  mut done : Bool
}

///|
/// Send a row-returning statement and return a streaming cursor over its rows. The
/// column definitions and their terminating EOF are consumed up front; the rows
/// themselves are read one at a time by [`next`](MysqlRowStream::next).
pub async fn MysqlConn::query_stream(
  self : MysqlConn,
  sql : String,
  params : Array[@moondb.Value],
) -> MysqlRowStream {
  if self.closed {
    raise @moondb.Closed
  }
  if self.streaming {
    raise @moonmysql.ProtocolError(
      "a query stream is still open on this connection; drain it or call close() first",
    )
  }
  let payload = Buffer()
  payload.write_byte(b'\x03') // COM_QUERY
  payload.write_bytes(
    @moonmysql.bind_params(sql, params, mode=self.quote_mode)[:],
  )
  self.write_packet(0, payload.to_bytes())
  let first = self.read_packet()
  if @moonmysql.is_err_packet(first) {
    raise @moonmysql.parse_err(first)
  }
  // OK ⇒ no result set: an already-exhausted stream.
  if @moonmysql.is_ok_packet(first) {
    return { conn: self, columns: [], pending: None, done: true, }
  }
  if first.length() > 0 && first[0].to_int() == 0xFB {
    raise @moonmysql.UnsupportedError("LOCAL INFILE is not supported")
  }
  let reader = @moonmysql.PacketReader::new(first)
  let column_count = reader.lenenc_uint().to_int()
  let columns : Array[@moonmysql.ColumnDef] = []
  for _ in 0..<column_count {
    columns.push(@moonmysql.parse_column_def(self.read_packet()))
  }
  let after_columns = self.read_packet()
  if @moonmysql.is_err_packet(after_columns) {
    raise @moonmysql.parse_err(after_columns)
  }
  // CLIENT_DEPRECATE_EOF is unset, so an EOF closes the column block; anything else
  // is defensively the first row.
  let pending = if @moonmysql.is_eof_packet(after_columns) {
    None
  } else {
    Some(after_columns)
  }
  self.streaming = true
  { conn: self, columns, pending, done: false, }
}

///|
/// The next row, or `None` at the EOF that ends the result set. An `ErrorResponse`
/// mid-stream is raised.
pub async fn MysqlRowStream::next(self : MysqlRowStream) -> @moondb.Row? {
  if self.done {
    return None
  }
  let packet = match self.pending {
    Some(p) => {
      self.pending = None
      p
    }
    None => self.conn.read_packet()
  }
  if @moonmysql.is_err_packet(packet) {
    self.finish()
    raise @moonmysql.parse_err(packet)
  }
  if @moonmysql.is_eof_packet(packet) {
    self.finish()
    return None
  }
  Some(@moonmysql.build_text_rows(self.columns, [packet])[0])
}

///|
/// Mark the stream done and release the connection's streaming guard.
fn MysqlRowStream::finish(self : MysqlRowStream) -> Unit {
  self.done = true
  self.conn.streaming = false
}

///|
/// Abandon the stream early, draining any unread rows to the terminating EOF so the
/// connection can run the next statement. Idempotent once the stream is done.
pub async fn MysqlRowStream::close(self : MysqlRowStream) -> Unit {
  if self.done {
    return
  }
  self.pending = None
  for ;; {
    let p = self.conn.read_packet()
    if @moonmysql.is_eof_packet(p) || @moonmysql.is_err_packet(p) {
      break
    }
  }
  self.finish()
}

///|
/// Begin a server-side transaction.
pub async fn MysqlConn::begin(self : MysqlConn) -> Unit {
  let _ = self.command(b"START TRANSACTION")
}

///|
/// Commit the current transaction.
pub async fn MysqlConn::commit(self : MysqlConn) -> Unit {
  let _ = self.command(b"COMMIT")
}

///|
/// Roll back the current transaction.
pub async fn MysqlConn::rollback(self : MysqlConn) -> Unit {
  let _ = self.command(b"ROLLBACK")
}

///|
/// Close the socket (best-effort, idempotent).
pub fn MysqlConn::close(self : MysqlConn) -> Unit {
  if !self.closed {
    self.closed = true
    self.tcp.close()
  }
}
