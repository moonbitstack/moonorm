"""The two tables, declared with SQLAlchemy 2.0's typed ORM.

The per-dialect storage types are pinned to the spelling `moonorm` uses for SQLite
(`INTEGER` for both `Int64` and `Bool`, `REAL` for `Real`), so the schema comparison
is about structure and not about which synonym a framework picked.
"""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import (
    REAL,
    BigInteger,
    Boolean,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    MetaData,
    Text,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

# What `moonorm` emits for `BigIntType` and `BoolType` on SQLite: an `INTEGER`, which
# is both the rowid alias an autoincrement key needs and the storage a boolean binds
# to. On the servers the variants fall away and the declared types are `BIGINT` and
# `BOOLEAN`.
SQLITE_INTEGER = Integer()


class Base(DeclarativeBase):
    metadata = MetaData()


class Account(Base):
    __tablename__ = "account"

    id: Mapped[int] = mapped_column(
        BigInteger().with_variant(SQLITE_INTEGER, "sqlite"),
        primary_key=True,
        autoincrement=True,
    )
    email: Mapped[str] = mapped_column(Text, nullable=False, unique=True)
    name: Mapped[str] = mapped_column(Text, nullable=False)
    score: Mapped[float] = mapped_column(
        REAL().with_variant(REAL, "sqlite"), nullable=False, server_default="0"
    )
    created: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)


class Article(Base):
    __tablename__ = "article"

    id: Mapped[int] = mapped_column(
        BigInteger().with_variant(SQLITE_INTEGER, "sqlite"),
        primary_key=True,
        autoincrement=True,
    )
    account_id: Mapped[int] = mapped_column(
        ForeignKey("account.id", ondelete="CASCADE"), nullable=False
    )
    title: Mapped[str] = mapped_column(Text, nullable=False)
    body: Mapped[str | None] = mapped_column(Text, nullable=True)
    published: Mapped[bool] = mapped_column(
        Boolean().with_variant(Integer, "sqlite"), nullable=False, server_default="0"
    )


# The one index the declaration carries. The name is the same one `moonorm` defaults
# to, so the two schemas can be compared by name rather than by order.
Index("ix_article_account_id", Article.__table__.c.account_id)
