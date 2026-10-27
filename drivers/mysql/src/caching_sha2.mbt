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
// Both halves of that last step belong elsewhere and are taken from there: the
// PEM envelope and the SubjectPublicKeyInfo are `mooncred/x509`'s, RSA-OAEP is
// `mooncrypt/rsa`'s. What stays is the obfuscation, which is MySQL's own.

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
/// The RSA public key inside the PEM `SubjectPublicKeyInfo` the server sends.
pub fn parse_rsa_public_key(pem : String) -> @rsa.PublicKey raise MysqlError {
  @x509.Spki::read(@x509.pem(pem)[:]).rsa() catch {
    err =>
      raise ProtocolError("caching_sha2: bad public key — " + err.to_string())
  }
}

///|
/// The caching_sha2_password full-auth token: the NUL-terminated password XORed
/// with the nonce (cycled), then RSA-OAEP encrypted under the server's public key.
///
/// `seed` is the 20 random octets OAEP masks with. MySQL's own client draws them
/// from OpenSSL; here they are a parameter, because this package has no entropy
/// source and a caller that reuses a seed should have to write that down.
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
  // SHA-1 with an empty label is what OpenSSL's RSA_PKCS1_OAEP_PADDING does,
  // which is what the server expects — and what `encrypt` defaults to.
  parse_rsa_public_key(pem).encrypt(obf.to_bytes()[:], seed=seed[:]) catch {
    _ =>
      raise ProtocolError(
        "caching_sha2: password too long for RSA-OAEP under this key",
      )
  }
}
