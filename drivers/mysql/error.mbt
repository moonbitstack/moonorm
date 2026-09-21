// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A failure raised while speaking the MySQL wire protocol. It is deliberately
/// distinct from `@moondb.DbError`: the pure codec and the socket transport raise
/// `MysqlError` (which carries wire-level specifics — a server error code, an
/// unsupported auth plugin, a malformed packet), and the `@moondb.Driver`
/// adapter maps it onto the coarse `DbError` cases at the public boundary.
///
/// * `ProtocolError` — a packet did not parse: short read, bad prefix byte, an
///   out-of-place packet in the result-set state machine.
/// * `ServerError`   — the server sent an ERR packet. Carries the numeric error
///   code, the 5-char SQLSTATE, and the human message verbatim.
/// * `UnsupportedError` — a code path this round does not implement (e.g. the
///   caching_sha2_password full-auth exchange, a LOCAL INFILE request).
pub(all) suberror MysqlError {
  ProtocolError(String)
  ServerError(Int, String, String)
  UnsupportedError(String)
} derive(Eq)

///|
/// A one-line rendering, e.g. `ServerError(1146, 42S02): Table 'test.t' doesn't exist`.
pub fn MysqlError::to_string(self : MysqlError) -> String {
  match self {
    ProtocolError(m) => "ProtocolError: " + m
    ServerError(code, state, msg) =>
      "ServerError(" + code.to_string() + ", " + state + "): " + msg
    UnsupportedError(m) => "UnsupportedError: " + m
  }
}

///|
pub impl Show for MysqlError with fn output(self : MysqlError, logger : &Logger) -> Unit {
  logger.write_string(self.to_string())
}

///|
pub extend MysqlError with Eq::{not_equal, equal}

///|
pub extend MysqlError with Show::{output}
