// Event hooks: a session's write path, observed and adjusted.
//
//     moon run examples/25-events
//
// The driver is the dependency-free `@moondb.MockDriver`, so the example runs anywhere.
// It records every statement's bound values as a row, which is enough to show that a
// `BeforeInsert` hook changed what was written and that an `AfterInsert` hook saw the
// statement that ran.

///|
/// The record the unit of work writes.
struct Post {
  id : Int32
  title : String
  updated_by : String
}

///|
fn post_row(r : @moondb.Row) -> Post raise @moondb.DbError {
  { id: r.int(0), title: r.text(1), updated_by: r.text(2), }
}

///|
fn post_model() -> @moonorm.Model[Post] {
  let fields : Array[@moonorm.Field[Post]] = [
    @moonorm.field("id", @schema.IntType, primary_key=true, p => p.id),
    @moonorm.field("title", @schema.TextType, nullable=false, p => p.title),
    @moonorm.field("updated_by", @schema.TextType, p => p.updated_by),
  ]
  @moonorm.Model::from_fields("posts", fields, post_row)
}

///|
fn main {
  let driver = @moondb.MockDriver::new()
  let sess = @moonorm.Session::new(driver)
  let model = post_model()
  try {
    // Two hooks on the insert: one stamps the row, one reports what was sent.
    sess.on(@session.BeforeInsert, ctx => {
      println("before_insert on " + ctx.table)
      ctx.set_column("updated_by", @moondb.Text("event-hook"))
    })
    sess.on(@session.AfterInsert, ctx => {
      println("after_insert: " + ctx.sql)
      println("  bound values: " + ctx.params.length().to_string())
    })
    sess.on(@session.BeforeFlush, _ctx => println("before_flush"))
    sess.on(@session.AfterFlush, _ctx => println("after_flush"))
    sess.add_record(model, { id: 1, title: "Hooks", updated_by: "", })
    sess.flush()
    // The mock driver stores each statement's parameters, so the stamped value is
    // readable back off the row it wrote.
    let rows = sess.query("SELECT * FROM posts", [])
    println("rows written: \{rows.length()}")
    println("updated_by as written: " + rows[0].text(2))
    // A hook that refuses stops the flush before the statement is sent.
    sess.on(@session.BeforeUpdate, _ctx => {
      raise @moondb.QueryError("updates are closed")
    })
    sess.update_record(model, { id: 1, title: "Changed", updated_by: "x", })
    let refused = try {
      sess.flush()
      "not refused"
    } catch {
      @moondb.QueryError(message) => message
      _ => "refused with another error"
    }
    println("refused: " + refused)
    println("still queued: \{sess.dirty_count()}")
    sess.close()
  } catch {
    error => println("error: " + error.to_string())
  }
}
