// The digests MySQL's authentication names, bound to `mooncrypt`.
//
// Nothing is implemented here. Every line hands off; what this file carries is
// the binding, so `caching_sha2.mbt` and `handshake.mbt` ask for a digest rather
// than restating which one on every call.

///|
/// SHA-1, which `mysql_native_password` and the OAEP padding around the public
/// key both use.
fn sha1(msg : Bytes) -> Bytes {
  @sha1.hash(msg[:])
}

///|
/// SHA-256, which `caching_sha2_password` uses.
fn sha256(msg : Bytes) -> Bytes {
  @sha2.hash(msg[:])
}

///|
/// SHA-512, which MariaDB's `client_ed25519` expands its secret through.
fn sha512(msg : Bytes) -> Bytes {
  @sha2.hash(msg[:], kind=Sha512)
}
