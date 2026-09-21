///|
/// Under `NO_BACKSLASH_ESCAPES` a backslash is an ordinary character, so escaping
/// with one leaves the value's own quote live and the statement is injectable. The
/// escape there is a doubled quote, and the backslash must be written as itself.
test "escaping follows the server's quoting mode" {
  let attack : Array[@moondb.Value] = [Text("' OR 1=1 -- ")]
  let backslash = @moonmysql.bind_params("SELECT * FROM t WHERE n = ?", attack)
  // Backslash mode: the quote is neutralised by the escape in front of it.
  assert_eq(@utf8.decode_lossy(backslash).contains("\\'"), true)
  let ansi = @moonmysql.bind_params(
    "SELECT * FROM t WHERE n = ?",
    attack,
    mode=DoubleQuote,
  )
  let text = @utf8.decode_lossy(ansi)
  // ANSI mode: the quote is doubled, so it stays inside the literal instead of
  // ending it — and no backslash is emitted, since the server would not read one.
  assert_eq(text.contains("''' OR 1=1"), true)
  assert_eq(text.contains("\\"), false)
  // A backslash in the value survives as itself; doubling it would corrupt it.
  let slash = @moonmysql.bind_params(
    "SELECT ?",
    [Text("a\\b")],
    mode=DoubleQuote,
  )
  assert_eq(@utf8.decode_lossy(slash), "SELECT 'a\\b'")
}
