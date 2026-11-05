// The revision graph. A migration history is not always a line: two people can branch
// from the same point and merge their work later, which is why a revision names its
// parents rather than carrying a number. Everything here is graph arithmetic over
// `Array[Revision]` — no SQL, no database — so the ordering rules are testable on
// their own and the runner only has to execute what they return.

///|
/// One revision: an identifier, the revisions it follows (`parents`), a message, and
/// the operations that apply and undo it.
///
/// `parents` is empty for a base revision, holds one id for a linear step, and two or
/// more for a merge. That is the whole difference between a chain and a DAG — the rest
/// of the runner walks whichever shape the parents describe.
pub(all) struct Revision {
  id : String
  parents : Array[String]
  name : String
  up : Array[Op]
  down : Array[Op]
}

///|
/// Declare a revision. A revision with no `parents` is a base: it applies to an empty
/// database. Two revisions may share a parent — that is a branch — and one revision
/// may name two parents — that is a merge.
pub fn Revision::new(
  id~ : String,
  parents~ : Array[String] = [],
  name~ : String,
  up~ : Array[Op],
  down~ : Array[Op],
) -> Revision {
  { id, parents, name, up, down, }
}

///|
/// Whether this revision applies to an empty database.
pub fn Revision::is_base(self : Revision) -> Bool {
  self.parents.length() == 0
}

///|
/// The revision's parent when it has exactly one, which is the linear case a caller
/// usually wants to follow back.
pub fn Revision::parent(self : Revision) -> String? {
  if self.parents.length() == 1 {
    Some(self.parents[0])
  } else {
    None
  }
}

///|
/// One line of a migration history: the revision, its parents, its message, and
/// whether the database has it.
pub(all) struct HistoryEntry {
  id : String
  parents : Array[String]
  name : String
  applied : Bool
}

///|
/// The revision with this id, or `None`.
pub fn Revision::find(revisions : Array[Revision], id : String) -> Revision? {
  revisions.iter().find_first(r => r.id == id)
}

///|
/// Refuse a revision set that cannot be walked: a duplicate id, or a parent that is
/// not in the set. Both are authoring mistakes that would otherwise surface as a
/// silently skipped step — a dangling parent reads as a base revision, so a typo
/// would apply a child before its parent ever existed.
pub fn Revision::check(
  revisions : Array[Revision],
) -> Unit raise @moondb.DbError {
  for i in 0..<revisions.length() {
    for j in 0..<revisions.length() {
      if i != j && revisions[i].id == revisions[j].id {
        raise @moondb.QueryError("duplicate revision id: " + revisions[i].id)
      }
    }
  }
  for r in revisions {
    for parent in r.parents {
      if Revision::find(revisions, parent) is None {
        raise @moondb.QueryError(
          "revision " + r.id + " names a parent that does not exist: " + parent,
        )
      }
    }
  }
}

///|
/// The revisions nothing else descends from — the tips of the graph. More than one
/// means the history has branches that have not been merged yet.
pub fn revision_heads(revisions : Array[Revision]) -> Array[String] {
  let out : Array[String] = []
  for r in revisions {
    let mut child = false
    for other in revisions {
      if other.parents.contains(r.id) {
        child = true
      }
    }
    if !child {
      out.push(r.id)
    }
  }
  out
}

///|
/// The revisions with no parents, ascending in declaration order.
pub fn revision_bases(revisions : Array[Revision]) -> Array[String] {
  revisions.filter(r => r.is_base()).map(r => r.id)
}

///|
/// Every revision reachable from `id` by following parents, `id` included — the set a
/// database at `id` must have applied.
pub fn Revision::ancestors(
  revisions : Array[Revision],
  id : String,
) -> Array[String] {
  let out : Array[String] = []
  Revision::collect(revisions, id, out)
  out
}

///|
/// Depth-first walk that appends each revision once, parents first, so the result is
/// already in an order an upgrade could follow.
fn Revision::collect(
  revisions : Array[Revision],
  id : String,
  out : Array[String],
) -> Unit {
  if out.contains(id) {
    return
  }
  match Revision::find(revisions, id) {
    None => ()
    Some(r) => {
      for parent in r.parents {
        Revision::collect(revisions, parent, out)
      }
      if !out.contains(id) {
        out.push(id)
      }
    }
  }
}

///|
/// The revisions in the order an upgrade must apply them: a revision comes after all
/// of its parents, and among the ones that are ready the earliest declared goes first
/// — so the order is a function of the input array, not of a hash or a clock.
///
/// Refuses a set `check` would refuse, and a cycle, which has no valid order at all.
pub fn Revision::order(
  revisions : Array[Revision],
) -> Array[String] raise @moondb.DbError {
  Revision::check(revisions)
  let out : Array[String] = []
  let remaining = revisions.copy()
  while remaining.length() > 0 {
    let mut picked = -1
    for i in 0..<remaining.length() {
      let mut ready = true
      for parent in remaining[i].parents {
        if !out.contains(parent) {
          ready = false
        }
      }
      if ready {
        picked = i
        break
      }
    }
    if picked < 0 {
      raise @moondb.QueryError(
        "the revision graph has a cycle among: " +
        remaining.map(r => r.id).join(", "),
      )
    }
    out.push(remaining[picked].id)
    remaining.remove(picked) |> ignore
  }
  out
}

///|
/// The revisions an upgrade to `target` has to apply, given what the database already
/// has, in the order to apply them.
///
/// `target` is `"head"` (the single tip; refuses when the graph has several), `"heads"`
/// (every tip), `"base"` (nothing), or a revision id. Revisions the database already
/// applied are left out, so a run that was interrupted resumes where it stopped.
pub fn Revision::pending(
  revisions : Array[Revision],
  applied : Array[String],
  target : String,
) -> Array[String] raise @moondb.DbError {
  let order = Revision::order(revisions)
  let wanted = Revision::resolve(revisions, target)
  let out : Array[String] = []
  for id in order {
    if !wanted.contains(id) || applied.contains(id) {
      continue
    }
    let mut ready = true
    for parent in Revision::find(revisions, id).unwrap().parents {
      if !applied.contains(parent) && !out.contains(parent) {
        ready = false
      }
    }
    if ready {
      out.push(id)
    } else {
      raise @moondb.QueryError(
        "revision " + id + " cannot be applied: its parents are not applied",
      )
    }
  }
  out
}

///|
/// The revisions a downgrade from `applied` to `target` has to undo, in the order to
/// undo them — descendants first, which is the reverse of the upgrade order.
pub fn Revision::doomed(
  revisions : Array[Revision],
  applied : Array[String],
  target : String,
) -> Array[String] raise @moondb.DbError {
  let order = Revision::order(revisions)
  let keep = Revision::resolve(revisions, target)
  let out : Array[String] = []
  for i = order.length() - 1; i >= 0; i = i - 1 {
    let id = order[i]
    if applied.contains(id) && !keep.contains(id) {
      out.push(id)
    }
  }
  out
}

///|
/// Turn a target into the set of revisions a database at that target has applied:
/// a revision id, or `"head"` / `"heads"` for the tips, or `"base"` for none.
pub fn Revision::resolve(
  revisions : Array[Revision],
  target : String,
) -> Array[String] raise @moondb.DbError {
  if target == "base" {
    return []
  }
  if target == "head" || target == "heads" {
    let heads = revision_heads(revisions)
    if target == "head" && heads.length() > 1 {
      raise @moondb.QueryError(
        "the history has " +
        heads.length().to_string() +
        " heads (" +
        heads.join(", ") +
        "); name one, or use \"heads\" to move to all of them",
      )
    }
    let out : Array[String] = []
    for head in heads {
      for id in Revision::ancestors(revisions, head) {
        if !out.contains(id) {
          out.push(id)
        }
      }
    }
    return out
  }
  if Revision::find(revisions, target) is None {
    raise @moondb.QueryError("unknown revision: " + target)
  }
  Revision::ancestors(revisions, target)
}

///|
/// The migration history, newest first — the order `history` prints in, so the tip
/// the database should be at is the first line.
pub fn Revision::history(
  revisions : Array[Revision],
  applied : Array[String],
) -> Array[HistoryEntry] raise @moondb.DbError {
  let order = Revision::order(revisions)
  let out : Array[HistoryEntry] = []
  for i = order.length() - 1; i >= 0; i = i - 1 {
    let r = Revision::find(revisions, order[i]).unwrap()
    out.push({
      id: r.id,
      parents: r.parents.copy(),
      name: r.name,
      applied: applied.contains(r.id),
    })
  }
  out
}
