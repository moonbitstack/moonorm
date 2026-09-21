///|
fn hex(b : Bytes) -> String {
  let d = "0123456789abcdef".to_array()
  let sb = StringBuilder()
  for i = 0; i < b.length(); i = i + 1 {
    let v = b[i].to_int()
    sb.write_char(d[(v >> 4) & 0xf])
    sb.write_char(d[v & 0xf])
  }
  sb.to_string()
}

///|
test "SHA-256 matches the NIST vectors" {
  assert_eq(
    hex(@sha2.hash(b""[:])),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
  assert_eq(
    hex(@sha2.hash(b"abc"[:])),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
}

///|
test "SCRAM-SHA-256 reproduces the RFC 7677 example vectors" {
  let salt = b"\x5b\x6d\x99\x68\x9d\x12\x35\x8e\xec\xa0\x4b\x14\x12\x36\xfa\x81"
  // base64 self-check on the known salt.
  assert_eq(@base64.encode(salt), "W22ZaJ0SNY7soEsUEjb6gQ==")
  let salted = @pbkdf2.key(b"pencil"[:], salt[:], digest, rounds=4096, len=32)
  assert_eq(
    hex(salted),
    "c4a49510323ab4f952cac1fa99441939e78ea74d6be81ddf7096e87513dc615d",
  )
  let auth = b"n=user,r=rOprNGfwEbeRWgbNEkqO,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096,c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0"
  // The client proof and the server signature the client sends and verifies.
  assert_eq(
    @base64.encode(scram_client_proof(salted, auth)),
    "dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
  )
  assert_eq(
    @base64.encode(scram_server_signature(salted, auth)),
    "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=",
  )
}

///|
test "scram_client_final produces the RFC 7677 client-final and server signature" {
  let (client_final, server_sig) = scram_client_final(
    b"pencil", "n=user,r=rOprNGfwEbeRWgbNEkqO", "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
  )
  assert_eq(
    client_final, "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
  )
  assert_eq(
    @base64.encode(server_sig),
    "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=",
  )
  // base64 round-trips the known salt.
  assert_eq(
    @base64.encode(@base64.decode_lossy("W22ZaJ0SNY7soEsUEjb6gQ==")),
    "W22ZaJ0SNY7soEsUEjb6gQ==",
  )
}
