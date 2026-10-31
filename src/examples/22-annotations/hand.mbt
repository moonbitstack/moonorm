///|
/// `Hero` written without annotations, the way a model is declared by hand: the
/// columns, a decoder over the typed accessors, and the projection an INSERT binds.
/// The annotated model must render and bind exactly as this one does.
let hand_heroes : @moonorm.Model[Hero] = @moonorm.Model::new(
  "heroes",
  [
    @moonorm.column("id", BigIntType, primary_key=true, autoincrement=true),
    @moonorm.column("name", TextType, nullable=false),
    @moonorm.column("secret_name", TextType, nullable=false, unique=true),
    @moonorm.column("age", IntType, checks=["age >= 0", "age < 1000"]),
    @moonorm.column("power", RealType, nullable=false, default="0"),
    @moonorm.column(
      "team_id",
      BigIntType,
      references=("teams", "id"),
      on_delete="SET NULL",
    ),
    @moonorm.column("email", TextType, nullable=false),
  ],
  r => {
    id: if r.is_null(0) {
      None
    } else {
      Some(r.int64(0))
    },
    name: r.text(1),
    secret: r.text(2),
    age: if r.is_null(3) {
      None
    } else {
      Some(r.int(3))
    },
    power: r.double(4),
    team_id: if r.is_null(5) {
      None
    } else {
      Some(r.int64(5))
    },
    email: Email(r.text(6)),
    visits: 0,
  },
  h => {
    let out : Array[(String, @moonorm.Value)] = []
    if h.id is Some(id) {
      out.push(("id", @moondb.Int64(id)))
    }
    let Email(email) = h.email
    out.push(("name", @moondb.Text(h.name)))
    out.push(("secret_name", @moondb.Text(h.secret)))
    out.push(
      (
        "age",
        match h.age {
          Some(a) => @moondb.Int(a)
          None => @moondb.Null
        },
      ),
    )
    out.push(("power", @moondb.Double(h.power)))
    out.push(
      (
        "team_id",
        match h.team_id {
          Some(t) => @moondb.Int64(t)
          None => @moondb.Null
        },
      ),
    )
    out.push(("email", @moondb.Text(email)))
    out
  },
  indexes=[@moonorm.index(["power"]), @moonorm.index(["name", "age"])],
)

///|
/// The two relations, written out.
let hand_team : @moonorm.Relation[Hero, Team] = @moonorm.belongs_to(
  Team::model(),
  "id",
  h => h.team_id,
)

///|
let hand_roster : @moonorm.Relation[Team, Hero] = @moonorm.has_many(
  hand_heroes,
  "team_id",
  t => t.id,
)
