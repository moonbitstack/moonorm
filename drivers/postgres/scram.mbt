// SCRAM-SHA-256 (RFC 5802 + RFC 7677) — the SASL mechanism modern PostgreSQL
// (14+) defaults to, so a driver that only speaks md5 cannot authenticate against a
// default server. The crypto is self-built: SHA-256 (FIPS 180-4), HMAC-SHA256,
// PBKDF2, and base64, then the SCRAM ClientProof / ServerSignature computation. The
// wire exchange in conn.mbt drives these; here is the pure, testable core.

///|
let sha256_k : Array[UInt] = [
  0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU, 0x59f111f1U, 0x923f82a4U,
  0xab1c5ed5U, 0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU,
  0x9bdc06a7U, 0xc19bf174U, 0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU, 0x2de92c6fU,
  0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU, 0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
  0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U, 0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU,
  0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U, 0xa2bfe8a1U, 0xa81a664bU,
  0xc24b8b70U, 0xc76c51a3U, 0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U, 0x19a4c116U,
  0x1e376c08U, 0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
  0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U, 0x90befffaU, 0xa4506cebU, 0xbef9a3f7U,
  0xc67178f2U,
]

///|
fn rotr32(x : UInt, n : Int) -> UInt {
  (x >> n) | (x << (32 - n))
}

///|
/// SHA-256 (FIPS 180-4).
pub fn sha256(msg : Bytes) -> Bytes {
  let h : Array[UInt] = [
    0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU, 0x510e527fU, 0x9b05688cU,
    0x1f83d9abU, 0x5be0cd19U,
  ]
  let padded = Buffer()
  padded.write_bytes(msg[:])
  padded.write_byte(b'\x80')
  while padded.length() % 64 != 56 {
    padded.write_byte(b'\x00')
  }
  let bitlen = msg.length().to_int64() * 8L
  for i = 7; i >= 0; i = i - 1 {
    padded.write_byte((bitlen >> (i * 8)).to_byte())
  }
  let data = padded.to_bytes()
  let nblocks = data.length() / 64
  for blk = 0; blk < nblocks; blk = blk + 1 {
    let base = blk * 64
    let w : Array[UInt] = Array::make(64, 0U)
    for i = 0; i < 16; i = i + 1 {
      let j = base + i * 4
      w[i] = (data[j].to_int().reinterpret_as_uint() << 24) |
        (data[j + 1].to_int().reinterpret_as_uint() << 16) |
        (data[j + 2].to_int().reinterpret_as_uint() << 8) |
        data[j + 3].to_int().reinterpret_as_uint()
    }
    for i = 16; i < 64; i = i + 1 {
      let s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3)
      let s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10)
      w[i] = w[i - 16] + s0 + w[i - 7] + s1
    }
    let mut a = h[0]
    let mut b = h[1]
    let mut c = h[2]
    let mut d = h[3]
    let mut e = h[4]
    let mut f = h[5]
    let mut g = h[6]
    let mut hh = h[7]
    for i = 0; i < 64; i = i + 1 {
      let big_s1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)
      let ch = (e & f) ^ (e.lnot() & g)
      let t1 = hh + big_s1 + ch + sha256_k[i] + w[i]
      let big_s0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)
      let maj = (a & b) ^ (a & c) ^ (b & c)
      let t2 = big_s0 + maj
      hh = g
      g = f
      f = e
      e = d + t1
      d = c
      c = b
      b = a
      a = t1 + t2
    }
    h[0] = h[0] + a
    h[1] = h[1] + b
    h[2] = h[2] + c
    h[3] = h[3] + d
    h[4] = h[4] + e
    h[5] = h[5] + f
    h[6] = h[6] + g
    h[7] = h[7] + hh
  }
  let out = Buffer()
  for i = 0; i < 8; i = i + 1 {
    out.write_byte((h[i] >> 24).to_byte())
    out.write_byte((h[i] >> 16).to_byte())
    out.write_byte((h[i] >> 8).to_byte())
    out.write_byte(h[i].to_byte())
  }
  out.to_bytes()
}

///|
/// HMAC-SHA256 (RFC 2104).
pub fn hmac_sha256(key : Bytes, msg : Bytes) -> Bytes {
  let block = 64
  let k0 = Array::make(block, b'\x00')
  let shortened = if key.length() > block { sha256(key) } else { key }
  for i = 0; i < shortened.length(); i = i + 1 {
    k0[i] = shortened[i]
  }
  let inner = Buffer()
  for i = 0; i < block; i = i + 1 {
    inner.write_byte((k0[i].to_int() ^ 0x36).to_byte())
  }
  inner.write_bytes(msg[:])
  let outer = Buffer()
  for i = 0; i < block; i = i + 1 {
    outer.write_byte((k0[i].to_int() ^ 0x5c).to_byte())
  }
  outer.write_bytes(sha256(inner.to_bytes())[:])
  sha256(outer.to_bytes())
}

///|
/// PBKDF2-HMAC-SHA256 producing a 32-byte key (SCRAM's `Hi`, dkLen = hLen so only the
/// first block is computed): T = U1 ^ U2 ^ … ^ Uc, U1 = HMAC(pw, salt‖INT32(1)).
pub fn pbkdf2_sha256(password : Bytes, salt : Bytes, iterations : Int) -> Bytes {
  let first = Buffer()
  first.write_bytes(salt[:])
  first.write_byte(b'\x00')
  first.write_byte(b'\x00')
  first.write_byte(b'\x00')
  first.write_byte(b'\x01')
  let mut u = hmac_sha256(password, first.to_bytes())
  let t = Array::make(32, 0)
  for i = 0; i < 32; i = i + 1 {
    t[i] = u[i].to_int()
  }
  for _iter = 1; _iter < iterations; _iter = _iter + 1 {
    u = hmac_sha256(password, u)
    for i = 0; i < 32; i = i + 1 {
      t[i] = t[i] ^ u[i].to_int()
    }
  }
  let out = Buffer()
  for i = 0; i < 32; i = i + 1 {
    out.write_byte(t[i].to_byte())
  }
  out.to_bytes()
}

///|
/// The SCRAM ClientProof for the AuthMessage: `ClientKey XOR HMAC(StoredKey,
/// AuthMessage)`, where ClientKey = HMAC(SaltedPassword, "Client Key") and
/// StoredKey = SHA256(ClientKey) (RFC 5802 §3).
pub fn scram_client_proof(salted : Bytes, auth_message : Bytes) -> Bytes {
  let client_key = hmac_sha256(salted, b"Client Key")
  let stored_key = sha256(client_key)
  let client_sig = hmac_sha256(stored_key, auth_message)
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
  hmac_sha256(hmac_sha256(salted, b"Server Key"), auth_message)
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
  let salted = pbkdf2_sha256(password, @base64.decode_lossy(salt_b64), iters)
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
