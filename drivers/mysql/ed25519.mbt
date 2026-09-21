// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// MariaDB's `client_ed25519` authentication (MariaDB protocol).
//
// The response shape is the protocol's and stays here; Ed25519 itself is
// `mooncrypt`'s.

///|
/// The MariaDB client_ed25519 response: the 64-byte Ed25519 signature of the
/// server's 32-byte challenge, keyed by the password.
///
/// MariaDB keys the signature with the password itself, where RFC 8032 would
/// expand a 32-byte seed — the derivation `PrivateKey::of_secret` exists for.
/// The plugin signs unconditionally, so an empty password expands to
/// `SHA-512("")` and still yields a valid signature.
pub fn mariadb_ed25519_response(password : Bytes, scramble : Bytes) -> Bytes {
  @ed25519.PrivateKey::of_secret(password[:]).sign(scramble[:])
}
