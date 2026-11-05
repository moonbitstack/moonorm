///|
test "sqlite opens through the driver" {
  let driver = @sqlite.SqliteDriver::open(":memory:") catch {
    error => abort("open failed: " + error.to_string())
  }
  let sess = @session.Session::new(driver)
  let rows = sess.query("SELECT 1", []) catch {
    error => abort("query failed: " + error.to_string())
  }
  assert_eq(rows.length(), 1)
  sess.close()
}
