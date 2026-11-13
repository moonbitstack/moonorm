"""The transcript both implementations have to reproduce.

One entry per case, in the order they run: the reads first, then the two writes
(an upsert and a cascading delete), because the writes change what the reads would
see. Each case yields rows of text; `transcript` renders them as
`case|field|field` lines, which is also the format `integration/realdb` writes.
"""

from __future__ import annotations

from typing import Callable, Sequence

from sqlalchemy import func, select, text
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.orm import Session

from models import Account, Article


def seed(session: Session) -> None:
    """Four accounts and four articles: one account with two, two with one, one with none."""
    session.add_all(
        [
            Account(id=1, email="alice@example.com", name="alice", score=4.5),
            Account(id=2, email="bob@example.com", name="bob", score=2.25),
            Account(id=3, email="carol@example.com", name="carol", score=7.25),
            Account(id=4, email="dave@example.com", name="dave", score=0.5),
            Article(id=1, account_id=1, title="Alpha", body="first", published=True),
            Article(id=2, account_id=1, title="Beta", body=None, published=False),
            Article(id=3, account_id=2, title="Gamma", body="third", published=True),
            Article(id=4, account_id=3, title="Delta", body="fourth", published=True),
        ]
    )
    session.commit()


def _names_ordered(session: Session) -> Sequence[Sequence[object]]:
    rows = session.execute(select(Account.name).order_by(Account.name)).scalars()
    return [[name] for name in rows]


def _article_counts(session: Session) -> Sequence[Sequence[object]]:
    query = (
        select(Account.name, func.count(Article.id))
        .join(Article, Article.account_id == Account.id)
        .group_by(Account.name)
        .having(func.count(Article.id) > 0)
        .order_by(Account.name)
    )
    return [list(row) for row in session.execute(query)]


def _silent_accounts(session: Session) -> Sequence[Sequence[object]]:
    query = (
        select(Account.name)
        .outerjoin(Article, Article.account_id == Account.id)
        .where(Article.id.is_(None))
        .order_by(Account.name)
    )
    return [[name] for name in session.execute(query).scalars()]


def _published_authors(session: Session) -> Sequence[Sequence[object]]:
    query = (
        select(Account.name)
        .join(Article, Article.account_id == Account.id)
        .where(Article.published.is_(True))
        .distinct()
        .order_by(Account.name)
    )
    return [[name] for name in session.execute(query).scalars()]


def _bodies(session: Session) -> Sequence[Sequence[object]]:
    query = select(
        Article.title, func.coalesce(Article.body, "(none)")
    ).order_by(Article.title)
    return [list(row) for row in session.execute(query)]


def _max_score(session: Session) -> Sequence[Sequence[object]]:
    value = session.execute(select(func.max(Account.score))).scalar_one()
    return [[value]]


def _ranked_titles(session: Session) -> Sequence[Sequence[object]]:
    rank = (
        func.row_number()
        .over(partition_by=Article.account_id, order_by=Article.id)
        .label("rank")
    )
    query = (
        select(Account.name, rank, Article.title)
        .join(Article, Article.account_id == Account.id)
        .order_by(Article.id)
    )
    return [list(row) for row in session.execute(query)]


def _name_prefix(session: Session) -> Sequence[Sequence[object]]:
    query = select(Account.name).where(Account.name.like("a%")).order_by(Account.name)
    return [[name] for name in session.execute(query).scalars()]


def _upsert_beta(session: Session) -> Sequence[Sequence[object]]:
    statement = sqlite_insert(Article).values(
        id=2,
        account_id=1,
        title="Beta II",
        body=None,
        published=False,
    )
    statement = statement.on_conflict_do_update(
        index_elements=[Article.id], set_={"title": statement.excluded.title}
    )
    session.execute(statement)
    session.commit()
    title = session.execute(
        select(Article.title).where(Article.id == 2)
    ).scalar_one()
    return [[title]]


def _cascade_delete(session: Session) -> Sequence[Sequence[object]]:
    session.execute(text("PRAGMA foreign_keys = ON"))
    session.execute(text("DELETE FROM account WHERE name = 'carol'"))
    session.commit()
    accounts = session.execute(select(func.count()).select_from(Account)).scalar_one()
    articles = session.execute(select(func.count()).select_from(Article)).scalar_one()
    return [[accounts, articles]]


# The two writes come last, and are the only cases a read-only run skips.
CASES: list[tuple[str, Callable[[Session], Sequence[Sequence[object]]], bool]] = [
    ("names-ordered", _names_ordered, False),
    ("article-counts", _article_counts, False),
    ("silent-accounts", _silent_accounts, False),
    ("published-authors", _published_authors, False),
    ("bodies", _bodies, False),
    ("max-score", _max_score, False),
    ("ranked-titles", _ranked_titles, False),
    ("name-prefix", _name_prefix, False),
    ("upsert-beta", _upsert_beta, True),
    ("cascade-delete", _cascade_delete, True),
]


def field(value: object) -> str:
    """One value, spelled the way both sides spell it."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, float):
        # 7.25 round-trips through both languages' shortest representation; a value
        # that needs more digits than that is not a value this transcript carries.
        return repr(value)
    return str(value)


def transcript_lines(session: Session, reads_only: bool = False) -> list[str]:
    lines: list[str] = []
    for name, case, mutates in CASES:
        if reads_only and mutates:
            continue
        for row in case(session):
            lines.append("|".join([name, *(field(v) for v in row)]))
    return lines


def transcript(session: Session, reads_only: bool = False) -> str:
    return "\n".join(transcript_lines(session, reads_only)) + "\n"
