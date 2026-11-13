"""A canonical description of a SQLite file's schema, read back with SQLite's own
pragmas rather than from either framework's model.

Two frameworks that describe the same table in different words have to leave the
same database behind, and that is what these lines compare: the storage class of
each column (SQLite's affinity, so `BIGINT` and `INTEGER` agree), whether it can be
null, whether it is part of the key, its default, the indexes the declaration asked
for, and the foreign keys with their actions. Physical spelling that no query can
observe — `INTEGER PRIMARY KEY AUTOINCREMENT` versus a table-level `PRIMARY KEY`
with `NOT NULL` — is normalised away, and the normalisation is written down here
rather than left implicit.
"""

from __future__ import annotations

import sqlite3


def affinity(declared: str) -> str:
    """SQLite's own rule for what a declared type stores as (section 3.1 of the docs)."""
    ty = declared.upper()
    if "INT" in ty:
        return "integer"
    if "CHAR" in ty or "CLOB" in ty or "TEXT" in ty:
        return "text"
    if "BLOB" in ty or ty == "":
        return "blob"
    if "REAL" in ty or "FLOA" in ty or "DOUB" in ty:
        return "real"
    return "numeric"


def _statements(conn: sqlite3.Connection) -> list[str]:
    # `PRAGMA` reads the table definition SQLite parsed, not the text anyone sent.
    return [row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")]


def _default(value: object, affinity_name: str) -> str:
    """A column default, spelled the same way whoever wrote it.

    SQLite keeps the default as the text it was given, so `DEFAULT 0` and
    `DEFAULT '0'` arrive as `0` and `'0'`. On a numeric column those are the same
    value, and the quote is not something a query can tell apart, so it comes off.
    """
    if value is None:
        return "-"
    text = str(value)
    if affinity_name in ("integer", "real", "numeric"):
        if len(text) >= 2 and text[0] == "'" and text[-1] == "'":
            text = text[1:-1]
    return text


def snapshot(conn: sqlite3.Connection) -> str:
    lines: list[str] = []
    for table in _statements(conn):
        for cid, name, declared, notnull, default, pk in conn.execute(
            f'PRAGMA table_info("{table}")'
        ):
            nullable = "not-null" if (notnull or pk) else "nullable"
            kind = affinity(declared)
            lines.append(
                "|".join(
                    [
                        "column",
                        table,
                        name,
                        kind,
                        nullable,
                        "pk" if pk else "-",
                        _default(default, kind),
                    ]
                )
            )
        for _, index, unique, origin, _partial in conn.execute(
            f'PRAGMA index_list("{table}")'
        ):
            if origin == "pk":
                # The key's own index; the column lines already carry the key.
                continue
            # An index a UNIQUE constraint created has no name of its own, so the
            # name is normalised rather than compared.
            label = "@unique" if origin == "u" else index
            columns = [
                row[2]
                for row in conn.execute(f'PRAGMA index_info("{index}")')
                if row[2] is not None
            ]
            lines.append(
                "|".join(
                    [
                        "index",
                        table,
                        label,
                        "unique" if unique else "-",
                        ",".join(columns),
                    ]
                )
            )
        for fk in conn.execute(f'PRAGMA foreign_key_list("{table}")'):
            # id, seq, table, from, to, on_update, on_delete, match
            lines.append(
                "|".join(
                    [
                        "fk",
                        table,
                        fk[3],
                        fk[2],
                        fk[4] if fk[4] is not None else "id",
                        (fk[6] or "").lower().replace(" ", "-") or "-",
                        (fk[5] or "").lower().replace(" ", "-") or "-",
                    ]
                )
            )
    lines.sort()
    return "\n".join(lines) + "\n"


def of(path: str) -> str:
    conn = sqlite3.connect(path)
    try:
        return snapshot(conn)
    finally:
        conn.close()
