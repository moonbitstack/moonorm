// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "mariadb client_ed25519 signs the challenge to the reference vector" {
  // password "pencil", 32-byte scramble 00..1f; the expected public key and
  // signature were produced by MariaDB's scheme (az = SHA512(password)) and
  // cross-verified as a valid Ed25519 signature by the `cryptography` library.
  let scr = FixedArray::make(32, b'\x00')
  for i in 0..<32 {
    scr[i] = i.to_byte()
  }
  let sig = @moonmysql.mariadb_ed25519_response(
    b"pencil",
    scr.unsafe_reinterpret_as_bytes(),
  )
  assert_eq(
    @base16.encode(sig),
    "439294572414f2d0088571388ae40a7c5268c182c6e19b96c9cf70a66bf8eee1866f1609b34cf21b96d5bda0c47a4937ed8be656a2c2c95c597373fca1eeaf0b",
  )
  // ed25519 signs unconditionally: an empty password still produces a valid
  // 64-byte signature (SHA-512("") expansion), cross-verified by `cryptography`.
  assert_eq(
    @base16.encode(
      @moonmysql.mariadb_ed25519_response(
        b"",
        scr.unsafe_reinterpret_as_bytes(),
      ),
    ),
    "1e7e2c09c0c0e5f755a202872d95c85c4b14d23a888e9c40a0e9323e1ed28dd4aee4a8197c2d2ca26942bf6496d61c60c63661959ab57706eb0bfda05749ad0f",
  )
}
