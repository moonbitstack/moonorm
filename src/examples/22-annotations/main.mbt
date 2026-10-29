///|
/// Models declared with `#orm` annotations. `models.g.mbt` is generated from
/// `models.mbt` by `cmd/orm`; a project wires the generator as a dev_build rule
/// (see the README). The program checks that the generated `Hero::model()`
/// renders and binds exactly as the hand-written model in `hand.mbt`, then runs a
/// round trip through a `Session`.
///
///     moon run src/examples/22-annotations --target native
fn render(params : Array[@moonorm.Value]) -> String {
  params.map(v => v.to_string()).join(", ")
}

///|
fn[T : Show] shown(x : T?) -> String {
  match x {
    Some(v) => v.to_string()
    None => "NULL"
  }
}

///|
fn same(what : String, generated : String, hand : String) -> Unit {
  if generated != hand {
    abort("\{what} differs:\n  generated: \{generated}\n  by hand:   \{hand}")
  }
}

///|
fn main {
  let dialects : Array[@moonorm.Dialect] = [Sqlite, Postgres, Mysql]
  println("-- CREATE TABLE, per dialect")
  for d in dialects {
    let sql = Team::model().create_table_sql_for(d)
    println(sql)
  }
  for d in dialects {
    let sql = Hero::model().create_table_sql_for(d)
    same("DDL", sql, hand_heroes.create_table_sql_for(d))
    println(sql)
  }
  let fresh : Hero = {
    id: None,
    name: "Nova",
    secret: "Ana",
    age: None,
    power: 9.5,
    team_id: Some(1),
    email: Email("nova@example.com"),
    visits: 3,
  }
  let stored = { ..fresh, id: Some(7), age: Some(31), }
  println("")
  println("-- INSERT; a key the database assigns is left out")
  for h in [fresh, stored] {
    let (sql, params) = Hero::model().insert_of(h).build()
    let (hand_sql, hand_params) = hand_heroes.insert_of(h).build()
    same("INSERT", sql, hand_sql)
    same("parameters", render(params), render(hand_params))
    println(sql)
    println("  [\{render(params)}]")
  }
  println("")
  println("-- round trip through a Session")
  try {
    let sess = @moonorm.Session::new(@moondb.MockDriver::new())
    sess.insert_record(Hero::model(), stored) |> ignore
    let back = sess.all(Hero::model())
    let hand = sess.all(hand_heroes)
    for h in back {
      println(
        "  #\{shown(h.id)} \{h.name} age=\{shown(h.age)} team=\{shown(h.team_id)} email=\{h.email.0} visits=\{h.visits}",
      )
    }
    let bound = (h : Hero) => render((hand_heroes.to_columns)(h).map(p => p.1))
    same("rows", back.map(bound).join("; "), hand.map(bound).join("; "))
    sess.close()
  } catch {
    e => abort("db error: " + e.to_string())
  }
  println("")
  println("generated and hand-written models agree")
}
