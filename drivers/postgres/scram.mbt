// SCRAM-SHA-256 as PostgreSQL speaks it (RFC 5802, RFC 7677).
//
// The flow is here because it is the protocol's; the digest, the MAC and the
// key derivation are `mooncrypt`'s. Which is the right split: SCRAM is a
// conversation, not an algorithm.

///|
/// The digest SCRAM-SHA-256 names, bound once so the flow does not restate it.
fn digest() -> &@spec.Hash {
  @sha2.Hasher::new()
}

///|
/// HMAC-SHA-256, which SCRAM uses at every step.
fn mac(key : Bytes, msg : Bytes) -> Bytes {
  @hmac.mac(key[:], msg[:], digest)
}

///|
/// The SCRAM ClientProof for the AuthMessage: `ClientKey XOR HMAC(StoredKey,
/// AuthMessage)`, where ClientKey = HMAC(SaltedPassword, "Client Key") and
/// StoredKey = SHA256(ClientKey) (RFC 5802 §3).
pub fn scram_client_proof(salted : Bytes, auth_message : Bytes) -> Bytes {
  let client_key = mac(salted, b"Client Key")
  let stored_key = @sha2.hash(client_key[:])
  let client_sig = mac(stored_key, auth_message)
  let out = Buffer()
  for i = 0; i < client_key.length(); i = i + 1 {
    out.write_byte((client_key[i].to_int() ^ client_sig[i].to_int()).to_byte())
  }
  out.to_bytes()
}

///|
/// The SCRAM ServerSignature: `HMAC(ServerKey, AuthMessage)`, ServerKey =
/// HMAC(SaltedPassword, "Server Key"). The client verifies the server's `v=` against
/// this to authenticate the server (RFC 5802 §3).
pub fn scram_server_signature(salted : Bytes, auth_message : Bytes) -> Bytes {
  mac(mac(salted, b"Server Key"), auth_message)
}

///|
fn atoi(s : String) -> Int {
  let mut n = 0
  for c in s {
    n = n * 10 + (c.to_int() - 48)
  }
  n
}

///|
/// Build the SCRAM client-final message and the expected server signature from the
/// server's first message (RFC 5802). `client_first_bare` is `n=…,r=clientnonce`;
/// `server_first` is `r=nonce,s=salt,i=iters`. Returns `(client_final_message,
/// server_signature)` — the client sends the first and verifies the server's `v=`
/// against the base64 of the second.
pub fn scram_client_final(
  password : Bytes,
  client_first_bare : String,
  server_first : String,
) -> (String, Bytes) raise DbError {
  let mut nonce = ""
  let mut salt_b64 = ""
  let mut iters = 0
  for part in server_first.split(",") {
    if part.has_prefix("r=") {
      nonce = part[2:].to_owned()
    } else if part.has_prefix("s=") {
      salt_b64 = part[2:].to_owned()
    } else if part.has_prefix("i=") {
      iters = atoi(part[2:].to_owned())
    }
  }
  // RFC 5802 §5.1: the server nonce MUST begin with the client nonce we sent.
  let mut client_nonce = ""
  for part in client_first_bare.split(",") {
    if part.has_prefix("r=") {
      client_nonce = part[2:].to_owned()
    }
  }
  guard client_nonce != "" && nonce.has_prefix(client_nonce) else {
    raise @moondb.QueryError(
      "SCRAM: server nonce does not extend the client nonce",
    )
  }
  let salted = @pbkdf2.key(
    password[:],
    @base64.decode_lossy(salt_b64)[:],
    digest,
    rounds=iters,
    len=32,
  )
  let client_final_wo = "c=biws,r=" + nonce
  let auth = @utf8.encode(
    client_first_bare + "," + server_first + "," + client_final_wo,
  )
  let proof = scram_client_proof(salted, auth)
  (
    client_final_wo + ",p=" + @base64.encode(proof),
    scram_server_signature(salted, auth),
  )
}
