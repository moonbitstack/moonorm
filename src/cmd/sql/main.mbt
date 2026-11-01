// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
async fn main {
  @cli.run(Sql::{ }, @env.args()[1:])
}
