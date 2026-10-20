///|
priv struct MTag {
  id : Int32
  name : String
}

///|
priv struct MPost {
  id : Int32
}

///|
/// A minimal target model for the many-to-many tests: a `tag` table (id, name).
fn mtag_model() -> Model[MTag] {
  Model::new(
    "tag",
    [column("id", IntType, primary_key=true), column("name", TextType)],
    r => { id: r.int(0), name: r.text(1), },
    t => [("id", @moondb.Int(t.id)), ("name", @moondb.Text(t.name))],
  )
}

///|
test "many_to_many builds a JOIN through the junction with a qualified projection" {
  let rel = many_to_many(
    mtag_model(),
    junction="post_tags",
    source_fk="post_id",
    target_fk="tag_id",
    target_key="id",
    source_key=fn(p : MPost) { Int(p.id) },
  )
  let post : MPost = { id: 7, }
  let (sql, params) = rel.query(post).build()
  // Target columns qualified (tag.*) so a same-named junction column is never
  // ambiguous; the join threads through the junction; the source key is bound.
  assert_eq(
    sql, "SELECT tag.id, tag.name FROM tag JOIN post_tags ON post_tags.tag_id = tag.id WHERE post_tags.post_id = ?",
  )
  assert_eq(params.length(), 1)
  assert_eq(params[0] == Int(7), true)
}
