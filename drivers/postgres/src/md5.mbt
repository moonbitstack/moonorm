// The MD5 password PostgreSQL's older authentication asks for
// (PostgreSQL protocol flow, §55.3).
//
// The flow is here because it is the protocol's; MD5 itself is `mooncrypt`'s,
// and the hex is `moonbase`'s.

///|
/// `"md5" + hex(md5(hex(md5(password + user)) + salt))`.
///
/// It is what the server asks for and nothing else uses it, which is why the
/// shape is stated rather than assembled from parts a caller might reorder.
pub fn pg_md5_password(
  user : String,
  password : String,
  salt : Bytes,
) -> String {
  let inner = @md5.hash(@utf8.encode((password + user)[:])[:])
  let salted = Buffer()
  salted.write_bytes(@utf8.encode(@base16.encode(inner[:]).to_lower()[:]))
  salted.write_bytes(salt)
  "md5" + @base16.encode(@md5.hash(salted.to_bytes()[:])[:]).to_lower()
}
