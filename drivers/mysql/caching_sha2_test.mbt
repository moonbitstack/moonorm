// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "caching_sha2 fast scramble matches the reference vector" {
  // nonce = 01 02 … 14 (20 bytes), password "pencil".
  let nb = FixedArray::make(20, b'\x00')
  for i in 0..<20 {
    nb[i] = (i + 1).to_byte()
  }
  let nonce = nb.unsafe_reinterpret_as_bytes()
  assert_eq(
    hex(@moonmysql.caching_sha2_scramble(b"pencil", nonce)),
    "804b188f4565dae5617113370e156183c91cfef6dd4714585f8d465f2150b271",
  )
  assert_eq(@moonmysql.caching_sha2_scramble(b"", nonce).length(), 0)
}

///|
// The 2048-bit RSA public key the reference vector was generated against.
let test_pubkey_pem : String =
  #|-----BEGIN PUBLIC KEY-----
  #|MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA4IuiVBUarKLBWojkZC06
  #|KKKupWKtQMVVZHDaJyDUaCO1xbUbTeXHG7Y1Pfs9OHS88/m+IsxBQQ960ssQL3Ix
  #|onJ6txhEMMx0y0vl1flqbdwFNVpYW3T0HjUXwJlt98kc6aKlOXn/4m4eInGlXjJP
  #|djv7w7WWNqZOeKXqy8qdJ7vFmME1sz7aC7p9NHBBSXPkY90rxLi7sQGzbb5uGB+W
  #|IWuH1IqGLECXnLlX/nnlkJGeOx7s06MxW9MKCQd2MKRThQlBW3JBr1SPCWvM6P1S
  #|4+e0K73Y4mPwmhdFPHX0ENQDnRhywVn13PFaUfxC4wwoRcsi/LJOGFEbbNEKyrHA
  #|xQIDAQAB
  #|-----END PUBLIC KEY-----

///|
test "parse_rsa_public_key recovers the modulus and exponent" {
  let (n, e) = @moonmysql.parse_rsa_public_key(test_pubkey_pem)
  assert_eq(e, 65537)
  // The modulus is 2048 bits, so exactly 256 octets.
  assert_eq(n.to_octets().length(), 256)
}

///|
test "rsa-oaep full-auth token reproduces the reference ciphertext" {
  // obf and seed are fixed, so OAEP is deterministic and matches Python's
  // manual EME-OAEP-SHA1 encode (cross-checked by a library OAEP decrypt).
  let nb = FixedArray::make(20, b'\x00')
  for i in 0..<20 {
    nb[i] = (i + 1).to_byte()
  }
  let seed = FixedArray::make(20, b'\x00')
  for i in 0..<20 {
    seed[i] = (100 + i).to_byte()
  }
  let ct = @moonmysql.caching_sha2_full_auth_token(
    b"pencil",
    nb.unsafe_reinterpret_as_bytes(),
    test_pubkey_pem,
    seed.unsafe_reinterpret_as_bytes(),
  )
  assert_eq(
    hex(ct),
    "c011d432182cdf3ef97f31623dfd75668a792e4f58301e9e33bf0fd14764517f9e58e849f96229441f38d817d77e73f89a37222a34ee07bbf3e8aab72c623f652b9b0a37e0ebdfea2d357d881126b37b74073b1ef9b8b372282e5e48cd7ede9df95da03c6c5e67df57efb9699197f7dbe070b26aa7ffc8c941758175434391154b267ad9ca88e90e37f6e3e5cdb2db89170bf88488991e18232f7dba2916d01da267e9dd98a5dbe23e4d178b2d67da5e148c8f8e39617dd03632cb3fa4b4b7741e3b051a6706e6956568a64cf21afea57094e1ba5410d9340edb8d4660b23e83f46dac86c81536b26cb3f4028a2d17a4480c96e406c427a3ec02c3af59c189f3",
  )
}
