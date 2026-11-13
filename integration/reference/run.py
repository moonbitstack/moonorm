"""Drive the SQLAlchemy half of the differential and check the two halves against
each other.

    python3 run.py emit --dir DIR      # build the reference side into DIR
    python3 run.py compare --dir DIR   # compare what both sides left in DIR

`emit` leaves a pristine `sa.db` (tables created from `models.py`, seeded, never
mutated), the schema transcript, the query transcript, and the read-only part of that
transcript. The `moonorm` side then fills `orm.db` in the same directory and checks
its own schema and rows against those transcripts. `compare` reads both database
files back:

  * the two files have the same schema, read with SQLite's own pragmas;
  * SQLAlchemy reflects `orm.db` and reads the rows the cases left in it, so the
    structure and the content both survive the trip out.
"""

from __future__ import annotations

import argparse
import pathlib
import sqlite3
import sys

from sqlalchemy import MetaData, create_engine, func, select
from sqlalchemy.orm import Session

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import cases
import snapshot
from models import Account, Article, Base


def _read_cases_only() -> str:
    """The transcript's read half, from a database nothing has written to."""
    scratch = create_engine("sqlite://")
    Base.metadata.create_all(scratch)
    with Session(scratch) as session:
        cases.seed(session)
        reads = cases.transcript(session, reads_only=True)
    scratch.dispose()
    return reads


def _write(path: pathlib.Path, text: str) -> None:
    # The transcripts are compared across two systems in CI, so the line ending is
    # part of the file: LF everywhere, whatever the host would have written.
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def emit(directory: pathlib.Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "sa.db"
    if path.exists():
        path.unlink()
    engine = create_engine(f"sqlite:///{path}")
    Base.metadata.create_all(engine)
    with Session(engine) as session:
        cases.seed(session)
    engine.dispose()

    # The transcript runs on a throwaway copy: the cases include an upsert and a
    # cascading delete, and `sa.db` has to stay as declared for the interop checks.
    scratch = create_engine("sqlite://")
    Base.metadata.create_all(scratch)
    with Session(scratch) as session:
        cases.seed(session)
        transcript = cases.transcript(session)
    scratch.dispose()

    # An empty file for the library's own run to fill in: the MoonBit side opens it,
    # creates its schema and seeds it, and `compare` then reads it back with SQLAlchemy.
    orm = directory / "orm.db"
    if orm.exists():
        orm.unlink()
    sqlite3.connect(orm).close()

    _write(directory / "sa_schema.txt", snapshot.of(str(path)))
    _write(directory / "sa_queries.txt", transcript)
    _write(directory / "sa_reads.txt", _read_cases_only())


def _reflect_orm_db(directory: pathlib.Path) -> list[str]:
    """SQLAlchemy reads the database this library created."""
    problems: list[str] = []
    path = directory / "orm.db"
    if not path.exists():
        return [f"missing {path}"]
    engine = create_engine(f"sqlite:///{path}")
    md = MetaData()
    md.reflect(bind=engine)
    names = sorted(md.tables)
    if names != ["account", "article"]:
        problems.append(f"reflected tables are {names}, wanted ['account', 'article']")
        engine.dispose()
        return problems
    declared = {
        "account": ["id", "email", "name", "score", "created"],
        "article": ["id", "account_id", "title", "body", "published"],
    }
    for table, columns in declared.items():
        got = [c.name for c in md.tables[table].columns]
        if got != columns:
            problems.append(f"{table} reflects as {got}, wanted {columns}")
    if not any(
        fk.target_fullname == "account.id" for fk in md.tables["article"].foreign_keys
    ):
        problems.append("article has no foreign key to account.id")
    indexes = sorted(ix.name for ix in md.tables["article"].indexes)
    if "ix_article_account_id" not in indexes:
        problems.append(
            f"article reflects indexes {indexes}, wanted ix_article_account_id"
        )
    # The rows the cases leave behind: three accounts, three articles, and the title
    # the upsert wrote. Reading them through reflected tables is the point — the
    # objects SQLAlchemy built come from the file, not from the models.
    account = md.tables["account"]
    article = md.tables["article"]
    with engine.connect() as conn:
        counts = (
            conn.execute(select(func.count()).select_from(account)).scalar_one(),
            conn.execute(select(func.count()).select_from(article)).scalar_one(),
        )
        title = conn.execute(
            select(article.c.title).where(article.c.id == 2)
        ).scalar_one()
        rows = [
            [str(r.id), r.email, r.name, str(r.score)] for r in conn.execute(
                select(account).order_by(account.c.id)
            )
        ]
    engine.dispose()
    if counts != (3, 3) or title != "Beta II":
        problems.append(
            f"rows read through reflection: {counts[0]} accounts, {counts[1]} "
            f"articles, title {title!r}; wanted 3, 3, 'Beta II'"
        )
    expected = [
        ["1", "alice@example.com", "alice", "4.5"],
        ["2", "bob@example.com", "bob", "2.25"],
        ["4", "dave@example.com", "dave", "0.5"],
    ]
    if rows != expected:
        problems.append(f"account rows read back are {rows}, wanted {expected}")
    return problems


def compare(directory: pathlib.Path) -> int:
    """Check the two halves, from this side.

    The schema of the two files has to be the same, and SQLAlchemy has to be able to
    reflect the file this library wrote and read the rows out of it. The other
    direction — this library reading `sa.db` — is asserted by the MoonBit tests, which
    compare it against the vectors this program generated.
    """
    problems: list[str] = []
    orm = directory / "orm.db"
    sa = directory / "sa.db"
    if not orm.exists() or not sa.exists():
        raise SystemExit(f"missing {orm} or {sa}: run `emit` and the moon test first")
    ours = snapshot.of(str(orm))
    theirs = snapshot.of(str(sa))
    if ours != theirs:
        import difflib

        problems.append(
            "the schema of orm.db and sa.db differ://n"
            + "".join(
                difflib.unified_diff(
                    theirs.splitlines(keepends=True),
                    ours.splitlines(keepends=True),
                    fromfile="sa.db",
                    tofile="orm.db",
                )
            )
        )
    problems += _reflect_orm_db(directory)
    if problems:
        print("\n".join(problems))
        return 1
    lines = len(theirs.splitlines())
    print(
        f"SQLAlchemy 2.0 and this library agree: {lines} schema facts on both files, "
        "SQLAlchemy reflected this library's database and read its rows"
    )
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["emit", "compare"])
    parser.add_argument("--dir", required=True, type=pathlib.Path)
    args = parser.parse_args(argv)
    if args.command == "emit":
        emit(args.dir)
        return 0
    return compare(args.dir)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
