///|
/// Streaming results in bounded memory (SQLAlchemy `stream_results` / `yield_per`):
/// `Session::stream_as` decodes one record at a time through a `RowStream` (`next` /
/// `close`), `Session::stream` yields raw rows through a `@moondb.Cursor`, and
/// `Session::query_stream` streams a raw statement. Over `@moondb.MockDriver` the
/// default cursor materialises the result, honouring the same pull interface a
/// native incremental cursor exposes.
///
///     moon run examples/18-streaming
struct Hero {
  id : Int32
  name : String
  power : Int32
}

///|
let heroes : @moonorm.Model[Hero] = @moonorm.Model::new(
  "heroes",
  [
    @moonorm.column("id", @moonorm.IntType, primary_key=true),
    @moonorm.column("name", @moonorm.TextType, nullable=false),
    @moonorm.column("power", @moonorm.IntType),
  ],
  r => { id: r.int(0), name: r.text(1), power: r.int(2), },
  h => {
    [
      ("id", @moondb.Int(h.id)),
      ("name", @moondb.Text(h.name)),
      ("power", @moondb.Int(h.power)),
    ]
  },
)

///|
#coverage.skip
fn main {
  try {
    let sess = @moonorm.Session::new(@moondb.MockDriver::new())
    let roster : Array[Hero] = [
      { id: 1, name: "lfanke", power: 233, },
      { id: 233, name: "qwq", power: 23333, },
      { id: 66666, name: "emm", power: 66666, },
    ]
    for h in roster {
      sess.insert_record(heroes, h) |> ignore
    }

    // Typed stream: pull one decoded record at a time until exhausted.
    println("-- stream_as (typed RowStream)")
    let rs = sess.stream_as(heroes, heroes.select())
    let mut n = 0
    for r = rs.next(); r is Some(h); r = rs.next() {
      println("  #\{h.id} \{h.name} power=\{h.power}")
      n = n + 1
    }
    rs.close()
    println("  streamed \{n} records")

    // Raw stream: a cursor over untyped rows.
    println("")
    println("-- stream (raw cursor)")
    let cur = sess.stream(@moonorm.select("heroes"))
    for row = cur.next(); row is Some(rr); row = cur.next() {
      println("  row width=\{rr.width()} name=\{rr.text(1)}")
    }
    cur.close()

    // query_stream off a raw SQL string, drained through the moondb helper.
    println("")
    println("-- query_stream (raw SQL) + drain")
    let qs = sess.query_stream("SELECT * FROM heroes", [])
    println("  drained \{@moondb.drain(qs).length()} rows")
    sess.close()
  } catch {
    e => println("db error: " + e.to_string())
  }
}
