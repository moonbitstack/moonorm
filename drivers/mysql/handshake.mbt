// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// MySQL client capability flags (the subset this round negotiates). We advertise
// protocol 41 with the secure-connection + pluggable-auth extensions, but
// deliberately leave CLIENT_DEPRECATE_EOF unset so result sets are framed by the
// classic EOF packets the text-protocol decoder keys off.

///|
pub let client_long_password : Int = 0x00000001

///|
pub let client_long_flag : Int = 0x00000004

///|
pub let client_connect_with_db : Int = 0x00000008

///|
pub let client_protocol_41 : Int = 0x00000200

///|
pub let client_transactions : Int = 0x00002000

///|
pub let client_secure_connection : Int = 0x00008000

///|
pub let client_plugin_auth : Int = 0x00080000

// MariaDB's extended server capabilities occupy the 4 bytes MySQL leaves reserved
// in HandshakeV10 — a distinct 32-bit space from the MySQL flags above. We read
// them (rather than blind-skip) so the MySQL-8 offset math is unchanged while a
// MariaDB server is still recognised. None are negotiated this round; they are
// named here for the record and future use.

///|
pub let mariadb_client_progress : Int = 0x00000001

///|
pub let mariadb_client_com_multi : Int = 0x00000002

///|
pub let mariadb_client_stmt_bulk_operations : Int = 0x00000004

///|
pub let mariadb_client_extended_metadata : Int = 0x00000008

///|
pub let mariadb_client_cache_metadata : Int = 0x00000010

///|
/// Which server dialect answered the handshake. Both speak the MySQL wire
/// protocol; they diverge in the version string and the extended capabilities.
pub(all) enum ServerKind {
  MySQL
  MariaDB
} derive(Eq, Debug)

///|
pub impl Show for ServerKind with fn output(self : ServerKind, logger : &Logger) -> Unit {
  logger.write_string(
    match self {
      MySQL => "MySQL"
      MariaDB => "MariaDB"
    },
  )
}

///|
/// Classify a raw handshake version string and recover the real version.
///
/// MariaDB 10+ prefixes its version with the fake `5.5.5-` sentinel (MySQL 5.5.5
/// was never released), so pre-10 clients that gate on the leading `5.` still
/// connect. Strip it to get the true version — e.g.
/// `5.5.5-11.4.2-MariaDB-ubu2404` → `11.4.2-MariaDB-ubu2404` as
/// [`ServerKind::MariaDB`]; a plain `8.0.35` is returned unchanged as
/// [`ServerKind::MySQL`].
pub fn parse_server_version(raw : String) -> (ServerKind, String) {
  let real = if raw.has_prefix("5.5.5-") { raw[6:].to_owned() } else { raw }
  let kind = if raw.has_prefix("5.5.5-") || real.contains("MariaDB") {
    ServerKind::MariaDB
  } else {
    ServerKind::MySQL
  }
  (kind, real)
}

///|
/// UTF-8 → bytes (protocol strings are UTF-8 on the wire).
fn string_to_bytes(s : String) -> Bytes {
  @utf8.encode(s[:])
}

///|
/// Bytes → String, lossily (server version, error text, text-protocol cells).
pub fn bytes_to_string(b : Bytes) -> String {
  @utf8.decode_lossy(b[:])
}

///|
/// The mysql_native_password challenge response:
/// `SHA1(password) XOR SHA1(salt ++ SHA1(SHA1(password)))`, 20 bytes. An empty
/// password produces an empty response (the server accepts a zero-length token).
pub fn native_password_scramble(password : Bytes, salt : Bytes) -> Bytes {
  if password.length() == 0 {
    return b""
  }
  let stage1 = sha1(password)
  let stage2 = sha1(stage1)
  let stage3 = sha1(concat_bytes(salt, stage2))
  let out = Buffer()
  for i in 0..<20 {
    out.write_byte((stage1[i].to_int() ^ stage3[i].to_int()).to_byte())
  }
  out.to_bytes()
}

///|
/// The server's initial Handshake packet (protocol version 10), decoded down to
/// the fields the client needs: the 20-byte auth salt, the negotiated
/// capabilities, and the auth-plugin name that selects the scramble.
pub struct Handshake {
  server_version : String
  server_kind : ServerKind
  connection_id : Int
  salt : Bytes
  capability : Int
  mariadb_capability : Int
  charset : Int
  status : Int
  auth_plugin : String
}

///|
/// Parse a protocol-10 initial Handshake payload. An ERR packet in its place
/// (`0xFF`, e.g. "Host is blocked" / "Too many connections") is surfaced as a
/// [`MysqlError::ServerError`].
pub fn parse_handshake(payload : Bytes) -> Handshake raise MysqlError {
  let r = PacketReader::new(payload)
  let proto = r.u8()
  if proto == 0xFF {
    let (code, state, msg) = parse_err_body(r)
    raise ServerError(code, state, msg)
  }
  if proto != 10 {
    raise ProtocolError(
      "unsupported handshake protocol version " + proto.to_string(),
    )
  }
  let (server_kind, server_version) = parse_server_version(
    bytes_to_string(r.string_nul()),
  )
  let connection_id = r.uint_le(4).to_int()
  let auth1 = r.bytes(8)
  let _filler = r.u8()
  let cap_lower = r.uint_le(2).to_int()
  let charset = r.u8()
  let status = r.uint_le(2).to_int()
  let cap_upper = r.uint_le(2).to_int()
  let capability = cap_lower | (cap_upper << 16)
  let auth_data_len = r.u8()
  // The 10 "reserved" bytes are 6 filler + 4 that MariaDB fills with its extended
  // capabilities (all zero on MySQL). Reading them keeps the byte count at 10, so
  // the auth-data-part-2 and plugin-name offsets below are identical on both.
  r.skip(6)
  let mariadb_capability = r.uint_le(4).to_int()
  let part2_len = {
    let x = auth_data_len - 8
    if x < 13 {
      13
    } else {
      x
    }
  }
  let auth2 = r.bytes(part2_len)
  let combined = concat_bytes(auth1, auth2)
  let salt = combined[0:20].to_owned()
  let auth_plugin = if (capability & client_plugin_auth) != 0 {
    bytes_to_string(r.string_nul())
  } else {
    "mysql_native_password"
  }
  {
    server_version,
    server_kind,
    connection_id,
    salt,
    capability,
    mariadb_capability,
    charset,
    status,
    auth_plugin,
  }
}

///|
/// Build the client's HandshakeResponse41 payload for `user`/`password`/`database`.
///
/// mysql_native_password and caching_sha2_password (MySQL 8's default, fast-path
/// scramble here and full auth driven in [`MysqlConn::connect`]) are both handled
/// directly. For any other plugin the client advertises mysql_native_password and
/// sends a native token, so a native-capable account authenticates and otherwise
/// the server drives an AuthSwitchRequest the connection layer answers (native or
/// caching_sha2) or rejects. Only a server that requires a non-native plugin *and*
/// does not offer pluggable auth is rejected here. client_ed25519 remains on the
/// README roadmap.
pub fn build_handshake_response(
  handshake : Handshake,
  user : String,
  password : Bytes,
  database : String,
) -> Bytes raise MysqlError {
  let (auth_response, advertised_plugin) = if handshake.auth_plugin ==
    "caching_sha2_password" {
    (caching_sha2_scramble(password, handshake.salt), "caching_sha2_password")
  } else if handshake.auth_plugin == "mysql_native_password" ||
    handshake.auth_plugin == "" {
    (
      native_password_scramble(password, handshake.salt),
      "mysql_native_password",
    )
  } else if (handshake.capability & client_plugin_auth) != 0 {
    // Negotiate down: advertise mysql_native_password and let the server offer its
    // plugin via an auth-method switch (handled in the connection layer).
    (
      native_password_scramble(password, handshake.salt),
      "mysql_native_password",
    )
  } else {
    raise UnsupportedError(
      "server requires auth plugin '" +
      handshake.auth_plugin +
      "' and does not offer pluggable auth; only mysql_native_password and " +
      "caching_sha2_password are implemented (client_ed25519 is on the README roadmap)",
    )
  }
  let mut caps = client_protocol_41 |
    client_secure_connection |
    client_plugin_auth |
    client_long_password |
    client_transactions |
    client_long_flag
  if database.length() > 0 {
    caps = caps | client_connect_with_db
  }
  let buf = Buffer()
  put_uint_le(buf, caps.to_int64(), 4)
  put_uint_le(buf, 0x01000000L, 4) // max packet size = 16 MiB
  buf.write_byte(b'\x21') // charset utf8_general_ci (33)
  for _ in 0..<23 {
    buf.write_byte(b'\x00')
  }
  put_string_nul(buf, string_to_bytes(user))
  buf.write_byte(auth_response.length().to_byte())
  buf.write_bytes(auth_response[:])
  if database.length() > 0 {
    put_string_nul(buf, string_to_bytes(database))
  }
  put_string_nul(buf, string_to_bytes(advertised_plugin))
  buf.to_bytes()
}

///|
/// Whether `payload` is an AuthSwitchRequest (`0xFE` lead byte with a body — the
/// length is what tells it apart from a 5-byte EOF, exactly as [`is_eof_packet`]
/// keys off `< 9`).
pub fn is_auth_switch_request(payload : Bytes) -> Bool {
  payload.length() >= 9 && payload[0].to_int() == 0xFE
}

///|
/// The 32-byte nonce from a `client_ed25519` AuthSwitchRequest. MariaDB sends
/// exactly `NONCE_BYTES` (= 32) with no NUL terminator and the client signs all of
/// them, so — unlike the native scramble — the full 32 bytes are read raw rather
/// than through the NUL-stripping [`parse_auth_switch_request`].
pub fn parse_ed25519_challenge(payload : Bytes) -> Bytes raise MysqlError {
  let r = PacketReader::new(payload)
  let _ = r.u8() // 0xFE
  let _ = r.string_nul() // plugin name
  r.bytes(32)
}

///|
/// Decode an AuthSwitchRequest into the plugin name the server wants and the fresh
/// 20-byte auth salt for it. The trailing NUL that follows the scramble is
/// dropped so the salt feeds [`native_password_scramble`] directly.
pub fn parse_auth_switch_request(
  payload : Bytes,
) -> (String, Bytes) raise MysqlError {
  let r = PacketReader::new(payload)
  let _ = r.u8() // 0xFE
  let plugin = bytes_to_string(r.string_nul())
  let rest = r.rest()
  let salt = if rest.length() >= 1 && rest[rest.length() - 1].to_int() == 0 {
    rest[0:rest.length() - 1].to_owned()
  } else {
    rest
  }
  (plugin, salt)
}

///|
pub extend ServerKind with Debug::{to_repr}

///|
pub extend ServerKind with Eq::{not_equal, equal}

///|
pub extend ServerKind with Show::{to_string, output}
