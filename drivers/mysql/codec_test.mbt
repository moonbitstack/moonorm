// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Build the length-encoded-string encoding of `s` (a `lenenc` length prefix
/// then the bytes) for assembling synthetic packets.
fn lenenc_str(s : Bytes) -> Bytes {
  let buf = Buffer()
  @moonmysql.put_lenenc_bytes(buf, s)
  buf.to_bytes()
}

///|
test "packet reader: fixed and length-encoded integers" {
  let buf = Buffer()
  @moonmysql.put_uint_le(buf, 0x1234L, 2)
  @moonmysql.put_uint_le(buf, 0x00FFFFFFL, 3)
  @moonmysql.put_lenenc_uint(buf, 10L) // 1-byte form
  @moonmysql.put_lenenc_uint(buf, 500L) // 0xFC + 2 bytes
  @moonmysql.put_lenenc_uint(buf, 100000L) // 0xFD + 3 bytes
  @moonmysql.put_lenenc_uint(buf, 0x0102030405L) // 0xFE + 8 bytes
  let r = @moonmysql.PacketReader::new(buf.to_bytes())
  assert_eq(r.uint_le(2), 0x1234L)
  assert_eq(r.uint_le(3), 0x00FFFFFFL)
  assert_eq(r.lenenc_uint(), 10L)
  assert_eq(r.lenenc_uint(), 500L)
  assert_eq(r.lenenc_uint(), 100000L)
  assert_eq(r.lenenc_uint(), 0x0102030405L)
  assert_eq(r.remaining(), 0)
}

///|
test "packet reader: NUL-string, lenenc-string, and NULL sentinel" {
  let buf = Buffer()
  @moonmysql.put_string_nul(buf, b"hello")
  @moonmysql.put_lenenc_bytes(buf, b"world")
  buf.write_byte(b'\xFB') // NULL sentinel
  let r = @moonmysql.PacketReader::new(buf.to_bytes())
  assert_eq(@moonmysql.bytes_to_string(r.string_nul()), "hello")
  assert_eq(r.lenenc_bytes().unwrap(), b"world")
  assert_eq(r.lenenc_bytes(), None)
}

///|
test "packet reader: short read raises ProtocolError" {
  let r = @moonmysql.PacketReader::new(b"\x01\x02")
  let got = try {
    let _ = r.uint_le(4)
    "no-raise"
  } catch {
    ProtocolError(_) => "protocol"
    _ => "other"
  }
  assert_eq(got, "protocol")
}

///|
test "scramble: matches the reference mysql_native_password vector" {
  let sb = Buffer()
  for i in 0..<20 {
    sb.write_byte((i + 1).to_byte())
  }
  let salt = sb.to_bytes()
  let scr = @moonmysql.native_password_scramble(b"secret", salt)
  assert_eq(@base16.encode(scr), "b32bb3a583e1340c0a1108d58b1be49781ad8c2f")
  // An empty password yields an empty response.
  assert_eq(@moonmysql.native_password_scramble(b"", salt).length(), 0)
}

///|
test "handshake: parse a protocol-10 initial packet" {
  let buf = Buffer()
  buf.write_byte(b'\x0a') // protocol version 10
  @moonmysql.put_string_nul(buf, b"8.0.35")
  @moonmysql.put_uint_le(buf, 4L, 4) // connection id
  buf.write_bytes(b"\x11\x22\x33\x44\x55\x66\x77\x88"[:]) // auth-plugin-data-1
  buf.write_byte(b'\x00') // filler
  @moonmysql.put_uint_le(buf, 0xF7FFL, 2) // capability lower
  buf.write_byte(b'\xff') // charset (utf8mb4)
  @moonmysql.put_uint_le(buf, 0x0002L, 2) // status flags
  @moonmysql.put_uint_le(buf, 0xFFFFL, 2) // capability upper (incl. CLIENT_PLUGIN_AUTH)
  buf.write_byte(b'\x15') // auth-plugin-data length = 21
  for _ in 0..<10 {
    buf.write_byte(b'\x00')
  } // reserved
  buf.write_bytes(b"\xaa\xbb\xcc\xdd\xee\xff\x00\x11\x22\x33\x44\x55\x00"[:]) // auth-2 (13)
  @moonmysql.put_string_nul(buf, b"mysql_native_password")
  let hs = @moonmysql.parse_handshake(buf.to_bytes())
  assert_eq(hs.server_version, "8.0.35")
  assert_eq(hs.connection_id, 4)
  assert_eq(hs.auth_plugin, "mysql_native_password")
  assert_eq(hs.salt.length(), 20)
  assert_eq((hs.capability & @moonmysql.client_plugin_auth) != 0, true)
  // salt = auth1(8) ++ first 12 bytes of auth2 (trailing NUL dropped)
  assert_eq(@base16.encode(hs.salt), "1122334455667788aabbccddeeff001122334455")
}

///|
/// The version-string parse is the tell that separates MySQL from MariaDB. Both
/// the `5.5.5-` sentinel form (MariaDB 10+) and a plain MySQL string are covered;
/// flipping either the prefix strip or the dialect test turns this red (mutation
/// check).
test "server version: MariaDB 5.5.5- sentinel, plain MariaDB, and MySQL" {
  // MariaDB 10+ hides the real version behind the fake "5.5.5-" prefix.
  let (k1, v1) = @moonmysql.parse_server_version("5.5.5-11.4.2-MariaDB-ubu2404")
  assert_eq(k1, @moonmysql.ServerKind::MariaDB)
  assert_eq(v1, "11.4.2-MariaDB-ubu2404")
  // A version that carries "MariaDB" without the sentinel is still MariaDB.
  let (k2, v2) = @moonmysql.parse_server_version("10.6.18-MariaDB")
  assert_eq(k2, @moonmysql.ServerKind::MariaDB)
  assert_eq(v2, "10.6.18-MariaDB")
  // A plain MySQL string is returned unchanged and classified MySQL.
  let (k3, v3) = @moonmysql.parse_server_version("8.0.35")
  assert_eq(k3, @moonmysql.ServerKind::MySQL)
  assert_eq(v3, "8.0.35")
}

///|
test "handshake: parse a MariaDB packet (ext caps read, salt + plugin intact)" {
  let buf = Buffer()
  buf.write_byte(b'\x0a') // protocol version 10
  @moonmysql.put_string_nul(buf, b"5.5.5-11.4.2-MariaDB-ubu2404")
  @moonmysql.put_uint_le(buf, 7L, 4) // connection id
  buf.write_bytes(b"\x11\x22\x33\x44\x55\x66\x77\x88"[:]) // auth-plugin-data-1
  buf.write_byte(b'\x00') // filler
  @moonmysql.put_uint_le(buf, 0xF7FFL, 2) // capability lower
  buf.write_byte(b'\x2d') // charset
  @moonmysql.put_uint_le(buf, 0x0002L, 2) // status flags
  @moonmysql.put_uint_le(buf, 0xFFFFL, 2) // capability upper (incl. CLIENT_PLUGIN_AUTH)
  buf.write_byte(b'\x15') // auth-plugin-data length = 21
  for _ in 0..<6 {
    buf.write_byte(b'\x00')
  } // 6 filler bytes
  @moonmysql.put_uint_le(buf, 0x0000001DL, 4) // MariaDB extended capabilities (bits 0..4)
  buf.write_bytes(b"\xaa\xbb\xcc\xdd\xee\xff\x00\x11\x22\x33\x44\x55\x00"[:]) // auth-2 (13)
  @moonmysql.put_string_nul(buf, b"mysql_native_password")
  let hs = @moonmysql.parse_handshake(buf.to_bytes())
  assert_eq(hs.server_kind, @moonmysql.ServerKind::MariaDB)
  assert_eq(hs.server_version, "11.4.2-MariaDB-ubu2404")
  assert_eq(hs.connection_id, 7)
  assert_eq(hs.mariadb_capability, 0x1D)
  assert_eq(hs.auth_plugin, "mysql_native_password")
  assert_eq(hs.salt.length(), 20)
  // Reading the 4 extended-cap bytes keeps the offsets identical to MySQL, so the
  // salt is still auth1(8) ++ first 12 bytes of auth2.
  assert_eq(@base16.encode(hs.salt), "1122334455667788aabbccddeeff001122334455")
}

///|
test "auth-switch: parse plugin name and fresh native salt" {
  let buf = Buffer()
  buf.write_byte(b'\xFE') // AuthSwitchRequest marker
  @moonmysql.put_string_nul(buf, b"mysql_native_password")
  for i in 0..<20 {
    buf.write_byte((i + 1).to_byte())
  } // 20-byte scramble
  buf.write_byte(b'\x00') // trailing NUL the server appends
  let payload = buf.to_bytes()
  assert_eq(@moonmysql.is_auth_switch_request(payload), true)
  let (plugin, salt) = @moonmysql.parse_auth_switch_request(payload)
  assert_eq(plugin, "mysql_native_password")
  assert_eq(salt.length(), 20) // trailing NUL dropped
  // The salt drives a valid 20-byte native response.
  assert_eq(@moonmysql.native_password_scramble(b"secret", salt).length(), 20)
}

///|
test "ERR packet: decoded into ServerError with code and sqlstate" {
  let buf = Buffer()
  buf.write_byte(b'\xFF')
  @moonmysql.put_uint_le(buf, 1146L, 2) // ER_NO_SUCH_TABLE
  buf.write_byte(b'\x23') // '#'
  buf.write_bytes(b"42S02"[:])
  buf.write_bytes(b"Table 'test.t' doesn't exist"[:])
  let e = @moonmysql.parse_err(buf.to_bytes())
  guard e is ServerError(code, state, msg) else {
    fail("parse_err should decode an ERR packet as a ServerError")
  }
  assert_eq(code, 1146)
  assert_eq(state, "42S02")
  assert_eq(msg, "Table 'test.t' doesn't exist")
}

///|
test "OK packet: affected rows and last insert id" {
  let buf = Buffer()
  buf.write_byte(b'\x00')
  @moonmysql.put_lenenc_uint(buf, 1L) // affected rows
  @moonmysql.put_lenenc_uint(buf, 42L) // last insert id
  @moonmysql.put_uint_le(buf, 0x0002L, 2) // status
  @moonmysql.put_uint_le(buf, 0L, 2) // warnings
  let ok = @moonmysql.parse_ok(buf.to_bytes())
  assert_eq(ok.affected_rows, 1L)
  assert_eq(ok.last_insert_id, 42L)
}

///|
/// Column defs matching `SELECT id, name FROM t` — the shape the integration
/// test asserts, decoded here from hand-built row packets so the row decoder is
/// covered off any backend and its mutation can be checked locally.
fn sample_columns() -> Array[@moonmysql.ColumnDef] {
  [
    { name: "id", column_type: 3, charset: 63, flags: 0, }, // LONG (int)
    { name: "name", column_type: 252, charset: 33, flags: 0, }, // BLOB w/ utf8 => Text
  ]
}

///|
test "text rows: decode (1, 'a') into typed moondb values" {
  let row = @moonmysql.concat_bytes(lenenc_str(b"1"), lenenc_str(b"a"))
  let rows = @moonmysql.build_text_rows(sample_columns(), [row])
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].int_by("id"), 1)
  assert_eq(rows[0].text_by("name"), "a")
}

///|
test "text rows: NULL sentinel, bigint, and binary blob" {
  let cols : Array[@moonmysql.ColumnDef] = [
    { name: "n", column_type: 3, charset: 63, flags: 0, }, // int, will be NULL
    { name: "big", column_type: 8, charset: 63, flags: 0, }, // LONGLONG
    { name: "raw", column_type: 252, charset: 63, flags: 0, }, // binary blob
  ]
  let buf = Buffer()
  buf.write_byte(b'\xFB') // NULL for column n
  @moonmysql.put_lenenc_bytes(buf, b"9223372036854775807") // int64 max
  @moonmysql.put_lenenc_bytes(buf, b"\x00\x01\xfe\xff") // raw bytes
  let rows = @moonmysql.build_text_rows(cols, [buf.to_bytes()])
  assert_eq(rows[0].is_null(0), true)
  assert_eq(rows[0].int64_by("big"), 9223372036854775807L)
  assert_eq(rows[0].blob_by("raw"), b"\x00\x01\xfe\xff")
}

///|
test "bind_params: escapes values and respects quoted placeholders" {
  let q = @moonmysql.bind_params("INSERT INTO t VALUES(?, ?, ?)", [
    @moondb.Int(1),
    @moondb.Text("a'b"),
    @moondb.Null,
  ])
  assert_eq(
    @moonmysql.bytes_to_string(q),
    "INSERT INTO t VALUES(1, 'a\\'b', NULL)",
  )
  // A '?' inside a string literal is not a placeholder.
  let q2 = @moonmysql.bind_params("SELECT '?' AS q, ? AS v", [@moondb.Int(7)])
  assert_eq(@moonmysql.bytes_to_string(q2), "SELECT '?' AS q, 7 AS v")
  // Count mismatch is rejected.
  let got = try {
    let _ = @moonmysql.bind_params("SELECT ?", [])
    "ok"
  } catch {
    ProtocolError(_) => "mismatch"
    _ => "other"
  }
  assert_eq(got, "mismatch")
}
