# ScrollSense — Assignment 1

Rohan Sai P. · DA24B049

Database design for ScrollSense, a short-video app with an LLM agent layer.
Written for SQLite 3.44+ (developed on 3.53.4).

## Files

| File | Contains |
|---|---|
| `schema.sql` | DDL: tables, constraints, keys, lookup data |
| `generate_data.py` | Seeded data generator (Deliverable E.3) |
| `queries.sql` | The thirteen queries with results and runtimes (Deliverable F) |
| `views.sql` | The five consumer views (Deliverable G.1) |
| `transactions.sql` | The three transaction scripts (Deliverable G.3) |
| `run_transactions.py` | Drives the transaction demos that need two connections |
| `rebuild.sh` | Drops and rebuilds the database from empty |

## Running it from an empty database

Check your SQLite version first. `ORDER BY` inside `group_concat` needs 3.44 or
later, and F8 is wrong on anything older.

```bash
sqlite3 --version
python3 -c "import sqlite3; print(sqlite3.sqlite_version)"
```

Both must report 3.44 or above.

Then, in order:

```bash
rm -f scrollsense.db scrollsense.db-wal scrollsense.db-shm
sqlite3 scrollsense.db < schema.sql
python3 generate_data.py
sqlite3 scrollsense.db < views.sql
```

Or run `./rebuild.sh`, which does the same four steps.

The generator takes about ten seconds and prints a row count per table. It is
seeded with 49, taken from roll number DA24B049, so it produces identical data
on every run.

## Running the queries

```bash
sqlite3 scrollsense.db ".timer on" ".read queries.sql" > /dev/null
```

Results go to `/dev/null` and timings print to the terminal.

## Running the transaction demos

```bash
python3 run_transactions.py
```

This builds its own scratch database (`tx_demo.db`) from `schema.sql`, so it
does not touch `scrollsense.db`. T2 and T3 open more than one connection to the
same file, which a single `sqlite3` session cannot do, which is why they are
driven from Python rather than run out of `transactions.sql` directly.

## Notes

`PRAGMA foreign_keys = ON` is per-connection, not per-database. It is set at
the top of `schema.sql`, again in `generate_data.py` after connecting, and
again in `queries.sql`. Any new connection needs it too, or foreign keys are
not enforced on that connection.

`PRAGMA journal_mode = WAL` is persisted in the database file, so it is set
once in `schema.sql`. The `-wal` and `-shm` files appearing next to
`scrollsense.db` are normal.

To change the data volumes, edit the parameter block at the top of
`generate_data.py`:

```python
SEED = 49
N_USERS = 5_000
N_VIDEOS = 20_000
N_IMPRESSIONS = 300_000
N_AGENT_SESSIONS = 2_000
SCALE = 1
```
