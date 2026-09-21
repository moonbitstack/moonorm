///|
/// Foreign-key relationships with explicit eager loading — MoonBit has no attribute
/// interception, so a related load is a call, not a silent lazy attribute access
/// (Diesel's preload / GORM's `Preload`). `has_many` (1:N), `belongs_to` (N:1), and
/// `many_to_many` each build the resolving `Select`; `Session::load` / `load_one` /
/// `load_many` run one, and `load_batch` / `load_one_batch` fetch related rows for many
/// sources in a single query (the N+1-avoiding `selectinload`), bucketing them back to
/// their sources in memory. The bound-value match keeps eager loading injection-safe.
/// Execution runs over a small fixed-rows driver standing in for the backend.
///
///     moon run examples/13-relationships
struct Team {
  id : Int
  name : String
}

///|
struct Hero {
  id : Int
  name : String
  team_id : Int
}

///|
struct Tag {
  id : Int
  label : String
}

///|
let team_model : @moonorm.Model[Team] = @moonorm.Model::new(
  "teams",
  [
    @moonorm.column("id", @moonorm.IntType, primary_key=true),
    @moonorm.column("name", @moonorm.TextType, nullable=false),
  ],
  r => { id: r.int(0), name: r.text(1), },
  t => [("id", @moondb.Int(t.id)), ("name", @moondb.Text(t.name))],
)

///|
let hero_model : @moonorm.Model[Hero] = @moonorm.Model::new(
  "heroes",
  [
    @moonorm.column("id", @moonorm.IntType, primary_key=true),
    @moonorm.column("name", @moonorm.TextType, nullable=false),
    @moonorm.column("team_id", @moonorm.IntType, references=("teams", "id")),
  ],
  r => { id: r.int(0), name: r.text(1), team_id: r.int(2), },
  h => {
    [
      ("id", @moondb.Int(h.id)),
      ("name", @moondb.Text(h.name)),
      ("team_id", @moondb.Int(h.team_id)),
    ]
  },
)

///|
let tag_model : @moonorm.Model[Tag] = @moonorm.Model::new(
  "tags",
  [
    @moonorm.column("id", @moonorm.IntType, primary_key=true),
    @moonorm.column("label", @moonorm.TextType, nullable=false),
  ],
  r => { id: r.int(0), label: r.text(1), },
  t => [("id", @moondb.Int(t.id)), ("label", @moondb.Text(t.label))],
)

///|
fn render(v : @moondb.Value) -> String {
  match v {
    Null => "Null"
    Bool(b) => "Bool(\{b})"
    Int(n) => "Int(\{n})"
    Int64(n) => "Int64(\{n})"
    Double(d) => "Double(\{d})"
    Text(s) => "Text(\"\{s}\")"
    Blob(b) => "Blob(\{b.length()} bytes)"
  }
}

///|
fn params_str(vals : Array[@moondb.Value]) -> String {
  "[" + vals.map(render).join(", ") + "]"
}

///|
/// A driver that returns a fixed result set for every query — enough to drive the
/// load / bucket logic without a real backend. Seed it with the rows a real WHERE
/// would return.
struct Rows {
  rows : Array[@moondb.Row]
}

///|
impl @moondb.Driver for Rows with fn execute(
  _self : Rows,
  _sql : String,
  _params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  { rows_affected: 0L, last_insert_id: 0L, }
}

///|
impl @moondb.Driver for Rows with fn query(
  self : Rows,
  _sql : String,
  _params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.rows
}

///|
impl @moondb.Driver for Rows with fn begin(_self : Rows) -> Unit raise @moondb.DbError {

}

///|
impl @moondb.Driver for Rows with fn commit(_self : Rows) -> Unit raise @moondb.DbError {

}

///|
impl @moondb.Driver for Rows with fn rollback(_self : Rows) -> Unit raise @moondb.DbError {

}

///|
impl @moondb.Driver for Rows with fn close(_self : Rows) -> Unit {

}

///|
fn hero_row(id : Int, name : String, team_id : Int) -> @moondb.Row {
  {
    columns: ["id", "name", "team_id"],
    values: [@moondb.Int(id), @moondb.Text(name), @moondb.Int(team_id)],
  }
}

///|
fn team_row(id : Int, name : String) -> @moondb.Row {
  { columns: ["id", "name"], values: [@moondb.Int(id), @moondb.Text(name)], }
}

///|
fn tag_row(id : Int, label : String) -> @moondb.Row {
  { columns: ["id", "label"], values: [@moondb.Int(id), @moondb.Text(label)], }
}

///|
#coverage.skip
fn main {
  let team1 : Team = { id: 1, name: "lfanke", }
  let hero1 : Hero = { id: 233, name: "qwq", team_id: 1, }

  // 1:N — a team to its heroes, matched by heroes.team_id.
  let children = @moonorm.has_many(hero_model, "team_id", (t : Team) => {
    @moondb.Int(t.id)
  })
  let (hsql, hparams) = children.query(team1).build()
  println("-- has_many query (team -> heroes)")
  println(hsql)
  println("params: " + params_str(hparams))
  println("source_value(team1): " + render(children.source_value(team1)))

  // N:1 — a hero to its single team, matched by teams.id.
  let parent = @moonorm.belongs_to(team_model, "id", (h : Hero) => {
    @moondb.Int(h.team_id)
  })
  let (psql, pparams) = parent.query(hero1).build()
  println("")
  println("-- belongs_to query (hero -> team)")
  println(psql)
  println("params: " + params_str(pparams))

  // The single batch query behind selectinload: WHERE team_id IN (…distinct keys…).
  let teams = [team1, { id: 2, name: "heke1228", }]
  let (bsql, bparams) = children.batch_query(teams).build()
  println("")
  println("-- batch_query (one round trip for many sources)")
  println(bsql)
  println("params: " + params_str(bparams))

  // N:M — heroes to tags through a junction table.
  let tagged = @moonorm.many_to_many(
    tag_model,
    junction="hero_tags",
    source_fk="hero_id",
    target_fk="tag_id",
    target_key="id",
    source_key=(h : Hero) => @moondb.Int(h.id),
  )
  let (msql, mparams) = tagged.query(hero1).build()
  println("")
  println("-- many_to_many query (hero -> tags via junction)")
  println(msql)
  println("params: " + params_str(mparams))

  // Now execute the loads against fixed result sets.
  try {
    // load: the team's children (the double returns the rows the WHERE would match).
    let s1 = @moonorm.Session::new(Rows::{
      rows: [hero_row(10, "qwq", 1), hero_row(11, "emm", 1)],
    })
    println("")
    println(
      "-- load (team1 children): " +
      s1.load(team1, children).map(fn(h) { h.name }).join(", "),
    )

    // load_batch: one query, children bucketed to their parents in memory.
    let s2 = @moonorm.Session::new(Rows::{
      rows: [
        hero_row(10, "qwq", 1),
        hero_row(11, "emm", 1),
        hero_row(12, "hhh", 2),
      ],
    })
    let buckets = s2.load_batch(teams, children)
    println("-- load_batch:")
    for i, t in teams {
      println(
        "     \{t.name} -> " + buckets[i].map(fn(h) { h.name }).join(", "),
      )
    }

    // load_one: a hero's single team.
    let s3 = @moonorm.Session::new(Rows::{ rows: [team_row(1, "lfanke")], })
    match s3.load_one(hero1, parent) {
      Some(t) => println("-- load_one (hero1's team): \{t.name}")
      None => println("-- load_one: none")
    }

    // load_one_batch: each hero's team, one query, matched in memory.
    let heroes = [hero1, { id: 234, name: "emm", team_id: 2, }]
    let s4 = @moonorm.Session::new(Rows::{
      rows: [team_row(1, "lfanke"), team_row(2, "heke1228")],
    })
    let parents = s4.load_one_batch(heroes, parent)
    println("-- load_one_batch:")
    for i, h in heroes {
      let pn = match parents[i] {
        Some(t) => t.name
        None => "-"
      }
      println("     \{h.name} -> \{pn}")
    }

    // load_many: a hero's tags through the junction.
    let s5 = @moonorm.Session::new(Rows::{
      rows: [tag_row(1, "qwe"), tag_row(2, "hhh")],
    })
    println(
      "-- load_many (hero1's tags): " +
      s5.load_many(hero1, tagged).map(fn(t) { t.label }).join(", "),
    )
  } catch {
    e => println("db error: " + e.to_string())
  }
}
