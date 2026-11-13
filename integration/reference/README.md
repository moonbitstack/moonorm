# Reference implementations

The two implementations this library is differenced against, and the harness that
runs them. Neither is vendored: the versions are pinned in `requirements.txt` and
installed by CI.

**SQLAlchemy 2.0**, for the same two tables and the same ten queries, used twice:

- **Differential.** Both implementations build a database from the same declaration
  and answer the same queries. The transcripts must be identical, line for line.
- **Interoperability.** SQLAlchemy opens a database this library created, and this
  library opens a database SQLAlchemy created. Neither is allowed to see anything
  but the schema it declared itself.

The models here are not a second opinion about what the schema should be — they
declare the same storage that `moonorm` declares for SQLite (`Int64` as `INTEGER`,
`Bool` as `INTEGER`, `Real` as `REAL`, text as `TEXT`), so a difference in the
transcripts is a difference in behaviour, not in vocabulary.

```
python3 -m pip install -r integration/reference/requirements.txt
python3 integration/reference/run.py emit --dir "$TMP/moonorm-reference"
```

`emit` writes `sa.db`, the SQLAlchemy side of the pair, plus the transcripts, and
`orm.db` as an empty file. The `moon test` run in `integration/realdb` reads
`MOONORM_REFERENCE_DIR`, answers the same ten queries against `sa.db`, and builds its
own tables in `orm.db`. `run.py compare` then reads both files back: same schema, and
SQLAlchemy reflects the file this library wrote.

**Migrations.** `alembic_ops.py` does the same for the other half of the library: it
creates a database from a "before" schema, hands Alembic the "after" one, and writes
the operations Alembic would generate. `integration/realdb/src/alembic_wbtest.mbt`
derives the same operations with `autogenerate_changes` for the same two schemas and
compares the lists.

`scripts/gen_reference_vectors.py` runs both references and writes what they answered
into `reference/expected/` and into `integration/realdb/src/reference_expected.mbt`,
which is what the tests assert against. `--check` fails when the tree holds anything
else.
