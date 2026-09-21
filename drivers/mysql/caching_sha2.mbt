// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// caching_sha2_password — MySQL 8's default authentication plugin. Two phases:
//
//   * fast auth: the client sends SHA256(pw) XOR SHA256(SHA256(SHA256(pw)) ‖ nonce);
//     if the server has the account's SHA256 digest cached it replies "fast success".
//   * full auth (cache miss, always on the first connection to a fresh server):
//     lacking TLS, the client fetches the server's RSA public key and returns the
//     NUL-terminated password XOR-obfuscated with the nonce, RSA-OAEP encrypted.
//
// The RSA-OAEP (RFC 8017, SHA-1 hash + MGF1-SHA-1, empty label) and the DER public
// key parse are self-built on the builtin BigInt; MySQL's client uses OpenSSL's
// RSA_PKCS1_OAEP_PADDING, which this reproduces.

///|
/// The caching_sha2_password fast-auth scramble:
/// `SHA256(pw) XOR SHA256( SHA256(SHA256(pw)) ‖ nonce )`, 32 bytes. An empty
/// password sends an empty token.
pub fn caching_sha2_scramble(password : Bytes, nonce : Bytes) -> Bytes {
  if password.length() == 0 {
    return b""
  }
  let d1 = sha256(password)
  let inner = sha256(concat_bytes(sha256(d1), nonce))
  let out = Buffer()
  for i in 0..<d1.length() {
    out.write_byte((d1[i].to_int() ^ inner[i].to_int()).to_byte())
  }
  out.to_bytes()
}

///|
/// A DER cursor over a byte string, enough of X.690 to walk a SubjectPublicKeyInfo.
priv struct DerReader {
  data : Bytes
  mut pos : Int
}

///|
fn DerReader::u8(self : DerReader) -> Int raise MysqlError {
  guard self.pos < self.data.length() else {
    raise ProtocolError("DER: read past end")
  }
  let v = self.data[self.pos].to_int()
  self.pos += 1
  v
}

///|
/// Read a DER length (short form, or long form with a leading count byte).
fn DerReader::length(self : DerReader) -> Int raise MysqlError {
  let first = self.u8()
  if first < 0x80 {
    first
  } else {
    let n = first & 0x7f
    let mut len = 0
    for _ in 0..<n {
      len = (len << 8) | self.u8()
    }
    len
  }
}

///|
/// Read a tag, assert it equals `want`, and return the field's content length.
fn DerReader::expect(self : DerReader, want : Int) -> Int raise MysqlError {
  let tag = self.u8()
  guard tag == want else {
    raise ProtocolError("DER: expected tag " + want.to_string())
  }
  self.length()
}

///|
fn DerReader::take(self : DerReader, n : Int) -> Bytes raise MysqlError {
  guard self.pos + n <= self.data.length() else {
    raise ProtocolError("DER: read past end")
  }
  let out = self.data[self.pos:self.pos + n].to_owned()
  self.pos += n
  out
}

///|
/// Parse a PEM `SubjectPublicKeyInfo` (`-----BEGIN PUBLIC KEY-----`) into the RSA
/// modulus and public exponent. Walks `SEQUENCE { AlgorithmIdentifier, BIT STRING
/// { RSAPublicKey { INTEGER n, INTEGER e } } }`.
pub fn parse_rsa_public_key(pem : String) -> (BigInt, BigInt) raise MysqlError {
  // Keep only the base64 body; the `-----BEGIN/END-----` lines contain letters
  // that are themselves valid base64 and would otherwise decode as key bytes.
  let body = StringBuilder()
  for line in pem.split("\n") {
    if !line.has_prefix("-") {
      body.write_string(line.to_owned())
    }
  }
  let der = @base64.decode_lossy(body.to_string())
  let r = DerReader::{ data: der, pos: 0, }
  r.expect(0x30) |> ignore // outer SEQUENCE
  let alg_len = r.expect(0x30) // AlgorithmIdentifier SEQUENCE
  r.take(alg_len) |> ignore // skip the algorithm id
  r.expect(0x03) |> ignore // BIT STRING
  r.u8() |> ignore // unused-bits count (0)
  r.expect(0x30) |> ignore // RSAPublicKey SEQUENCE
  let n_len = r.expect(0x02) // INTEGER n
  let n = BigInt::from_octets(strip_der_int(r.take(n_len))[:])
  let e_len = r.expect(0x02) // INTEGER e
  let e = BigInt::from_octets(strip_der_int(r.take(e_len))[:])
  (n, e)
}

///|
/// Drop a DER INTEGER's leading sign byte (`0x00` prepended to keep it positive).
fn strip_der_int(b : Bytes) -> Bytes {
  if b.length() > 1 && b[0].to_int() == 0 {
    b[1:].to_owned()
  } else {
    b
  }
}

///|
/// MGF1 with SHA-1 (RFC 8017 B.2.1): the mask-generation function OAEP masks with.
fn mgf1_sha1(seed : Bytes, length : Int) -> Bytes {
  let out = Buffer()
  let mut counter = 0
  while out.length() < length {
    let c = Buffer()
    c.write_bytes(seed[:])
    c.write_byte((counter >> 24).to_byte())
    c.write_byte((counter >> 16).to_byte())
    c.write_byte((counter >> 8).to_byte())
    c.write_byte(counter.to_byte())
    out.write_bytes(sha1(c.to_bytes())[:])
    counter += 1
  }
  out.to_bytes()[0:length].to_owned()
}

///|
/// EME-OAEP encode `msg` (SHA-1, empty label) to `k` octets with the given `seed`,
/// then RSA-encrypt: `EM^e mod n`. `seed` must be 20 random bytes (RFC 8017 §7.1.1).
pub fn rsa_oaep_sha1_encrypt(
  msg : Bytes,
  n : BigInt,
  e : BigInt,
  seed : Bytes,
) -> Bytes raise MysqlError {
  let k = n.to_octets().length()
  let hlen = 20
  // RFC 8017 §7.1.1 step 1b: a message longer than k − 2·hLen − 2 does not fit;
  // reject it rather than build a malformed (out-of-range) padded block.
  if msg.length() > k - 2 * hlen - 2 {
    raise ProtocolError(
      "caching_sha2: password too long for RSA-OAEP under this key",
    )
  }
  let lhash = sha1(b"")
  let db = Buffer()
  db.write_bytes(lhash[:])
  for _ in 0..<(k - msg.length() - 2 * hlen - 2) {
    db.write_byte(b'\x00')
  }
  db.write_byte(b'\x01')
  db.write_bytes(msg[:])
  let db_bytes = db.to_bytes()
  let db_mask = mgf1_sha1(seed, k - hlen - 1)
  let masked_db = Buffer()
  for i in 0..<db_bytes.length() {
    masked_db.write_byte((db_bytes[i].to_int() ^ db_mask[i].to_int()).to_byte())
  }
  let masked_db_bytes = masked_db.to_bytes()
  let seed_mask = mgf1_sha1(masked_db_bytes, hlen)
  let em = Buffer()
  em.write_byte(b'\x00')
  for i in 0..<hlen {
    em.write_byte((seed[i].to_int() ^ seed_mask[i].to_int()).to_byte())
  }
  em.write_bytes(masked_db_bytes[:])
  let m = BigInt::from_octets(em.to_bytes()[:])
  m.pow(e, modulus=n).to_octets(length=k)
}

///|
/// The caching_sha2_password full-auth token: the NUL-terminated password XORed
/// with the nonce (cycled), then RSA-OAEP encrypted under the server's public key.
pub fn caching_sha2_full_auth_token(
  password : Bytes,
  nonce : Bytes,
  pem : String,
  seed : Bytes,
) -> Bytes raise MysqlError {
  guard nonce.length() > 0 else {
    raise ProtocolError("caching_sha2: empty server nonce")
  }
  let obf = Buffer()
  for i in 0..<(password.length() + 1) {
    let p = if i < password.length() { password[i].to_int() } else { 0 }
    obf.write_byte((p ^ nonce[i % nonce.length()].to_int()).to_byte())
  }
  let (n, e) = parse_rsa_public_key(pem)
  rsa_oaep_sha1_encrypt(obf.to_bytes(), n, e, seed)
}
