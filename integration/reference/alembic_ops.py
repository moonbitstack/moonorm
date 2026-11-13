"""What Alembic's autogenerate says about one model change, as canonical lines.

The change is the same on both sides: a table and a column appear, a column and an
index disappear, and one column's storage type changes. Alembic computes the
operations from a live database and a target `MetaData`; this module renders them as
lines the library's own `autogenerate_changes` output can be compared against.

Only the four kinds of operation both implementations produce are compared; anything
Alembic reports beyond them would show up as an `other|…` line rather than being
quietly dropped.
"""

from __future__ import annotations

import pathlib

from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from sqlalchemy import (
    Column,
    ForeignKey,
    Index,
    Integer,
    MetaData,
    Numeric,
    REAL,
    Table,
    Text,
    create_engine,
)


def _before() -> MetaData:
    md = MetaData()
    account = Table(
        "account",
        md,
        Column("id", Integer, primary_key=True),
        Column("email", Text, nullable=False, unique=True),
        Column("name", Text, nullable=False),
        Column("nickname", Text, nullable=True),
        Column("score", REAL, nullable=False, server_default="0"),
    )
    article = Table(
        "article",
        md,
        Column("id", Integer, primary_key=True),
        Column("account_id", Integer, ForeignKey("account.id", ondelete="CASCADE"), nullable=False),
        Column("title", Text, nullable=False),
        Column("body", Text, nullable=True),
        Column("published", Integer, nullable=False, server_default="0"),
    )
    Index("ix_account_name", account.c.name)
    Index("ix_article_account_id", article.c.account_id)
    return md


def _after() -> MetaData:
    md = MetaData()
    account = Table(
        "account",
        md,
        Column("id", Integer, primary_key=True),
        Column("email", Text, nullable=False, unique=True),
        Column("name", Text, nullable=False),
        # The storage type changed: the column is no longer a floating-point one.
        Column("score", Numeric, nullable=False, server_default="0"),
    )
    article = Table(
        "article",
        md,
        Column("id", Integer, primary_key=True),
        Column("account_id", Integer, ForeignKey("account.id", ondelete="CASCADE"), nullable=False),
        Column("title", Text, nullable=False),
        Column("body", Text, nullable=True),
        Column("published", Integer, nullable=False, server_default="0"),
        Column("subtitle", Text, nullable=True),
    )
    Table(
        "tag",
        md,
        Column("id", Integer, primary_key=True),
        Column("label", Text, nullable=False),
    )
    Index("ix_article_account_id", article.c.account_id)
    Index("ix_article_title", article.c.title)
    return md


def _line(diff: object) -> str:
    # Alembic groups the per-column `modify_*` operations in a tuple of their own.
    if isinstance(diff[0], tuple):
        return " ".join(_line(inner) for inner in diff)
    kind = diff[0]
    if kind in ("add_table", "remove_table"):
        return f"{'add' if kind == 'add_table' else 'remove'}_table|{diff[1].name}"
    if kind in ("add_column", "remove_column"):
        # (kind, schema, table name, Column)
        return (
            f"{'add' if kind == 'add_column' else 'remove'}_column"
            f"|{diff[2]}|{diff[3].name}"
        )
    if kind == "modify_type":
        # (kind, schema, table name, column name, existing, target)
        return f"alter_type|{diff[2]}|{diff[3]}"
    if kind == "modify_nullable":
        return f"alter_nullable|{diff[2]}|{diff[3]}"
    if kind in ("add_index", "remove_index"):
        # By name: an index is the unit both generators create and drop, and the name
        # is the only part of it a `DROP INDEX` carries.
        index = diff[1]
        return (
            f"{'add' if kind == 'add_index' else 'remove'}_index"
            f"|{index.table.name}|{index.name}"
        )
    return f"other|{kind}"


def ops(directory: pathlib.Path) -> list[str]:
    """The operations Alembic derives, sorted, for the change above."""
    path = directory / "alembic.db"
    if path.exists():
        path.unlink()
    engine = create_engine(f"sqlite:///{path}")
    _before().create_all(engine)
    with engine.connect() as conn:
        context = MigrationContext.configure(conn)
        diffs = compare_metadata(context, _after())
    engine.dispose()
    return sorted(_line(diff) for diff in diffs)


def emit(directory: pathlib.Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    lines = ops(directory)
    with open(directory / "alembic_ops.txt", "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(lines) + "\n")


def main(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["emit"])
    parser.add_argument("--dir", required=True, type=pathlib.Path)
    args = parser.parse_args(argv)
    emit(args.dir)
    return 0


if __name__ == "__main__":
    import sys

    raise SystemExit(main(sys.argv[1:]))
