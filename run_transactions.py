#!/usr/bin/env python3
"""Run the three transaction demonstrations from transactions.sql.

T2 and T3 need more than one connection to the same database file, which a
single sqlite3 session cannot do, so this script drives them.
"""

import os
import sqlite3

DB = "tx_demo.db"
SCHEMA = "schema.sql"


def fresh():
    for f in (DB, DB + "-wal", DB + "-shm"):
        if os.path.exists(f):
            os.remove(f)
    con = sqlite3.connect(DB)
    con.executescript(open(SCHEMA).read())
    con.execute("PRAGMA foreign_keys = ON")
    con.executescript("""
        INSERT INTO AppUser VALUES (1,'alice','A','+911111111111',NULL,'active','2026-01-01T00:00:00Z',NULL);
        INSERT INTO AppUser VALUES (2,'bobby','B','+912222222222',NULL,'active','2026-01-01T00:00:00Z',NULL);
        INSERT INTO Follow VALUES (1,2,'2026-02-01T00:00:00Z',NULL,NULL);
        INSERT INTO Follow VALUES (2,1,'2026-02-02T00:00:00Z',NULL,NULL);
        INSERT INTO Creator VALUES (1,'2026-01-01T00:00:00Z');
        INSERT INTO Reviewer VALUES (1,'classifier','auto-mod-v3');
        INSERT INTO Reviewer VALUES (2,'human','reviewer_02');
        INSERT INTO Video VALUES (1,1,NULL,45000,'a clip','2026-01-05T00:00:00Z');
        INSERT INTO ModerationDecision VALUES (1,1,1,'pending','2026-01-05T00:00:00Z');
        INSERT INTO ModerationDecision VALUES (2,1,1,'live','2026-01-05T00:05:00Z');
        INSERT INTO HandleChange VALUES (1,'2026-01-01T00:00:00Z','alice');
        INSERT INTO Signal VALUES (1,2,1,'like','2026-03-02T10:00:00Z');
    """)
    con.commit()
    con.isolation_level = None
    return con


CURRENT_STATE = """SELECT state FROM ModerationDecision WHERE video_id = 1
                   ORDER BY decided_at DESC LIMIT 1"""


def t1(con):
    """T1, run on a block rather than a like retraction.

    The task sheet describes T1 as ending a like row and writing a
    negative-signal row, then failing between the two. Because of the
    assumption made in A4, a retraction here is one insert, so there is no
    second write to fail after. A block is the operation that is two writes:
    since we assumed in A12 that a block ends any follows in both directions,
    it inserts a Block row and updates the Follow rows.
    """
    print("T1  a block breaks follows in both directions, atomically")
    before = con.execute("SELECT (SELECT count(*) FROM Follow WHERE ended_at IS NULL),"
                         " (SELECT count(*) FROM Block)").fetchone()
    print(f"    before: {before[0]} open follows, {before[1]} blocks")
    try:
        con.execute("BEGIN")
        con.execute("INSERT INTO Block VALUES (1,2,'2026-03-01T00:00:00Z',NULL)")
        con.execute("""UPDATE Follow SET ended_at='2026-03-01T00:00:00Z', end_reason='blocked'
                       WHERE ended_at IS NULL
                         AND ((follower_id=1 AND followee_id=2)
                           OR (follower_id=2 AND followee_id=1))""")
        con.execute("INSERT INTO Block VALUES (1,1,'2026-03-01T00:00:00Z',NULL)")
        con.execute("COMMIT")
    except sqlite3.IntegrityError as e:
        print(f"    injected failure: {e}")
        con.execute("ROLLBACK")
    after = con.execute("SELECT (SELECT count(*) FROM Follow WHERE ended_at IS NULL),"
                        " (SELECT count(*) FROM Block)").fetchone()
    print(f"    after:  {after[0]} open follows, {after[1]} blocks")
    print(f"    consistent: {before == after}")

    con.execute("INSERT INTO Signal VALUES (2,2,1,'like_retracted','2026-03-02T10:00:30Z')")
    state = con.execute("""SELECT signal_type FROM Signal
                           WHERE user_id=2 AND video_id=1
                             AND signal_type IN ('like','like_retracted')
                           ORDER BY occurred_at DESC LIMIT 1""").fetchone()[0]
    print(f"    for contrast, a retraction is one write; like state reads as {state}")
    print()


def t2():
    print("T2  an uncommitted moderation decision is invisible to other readers")
    writer = sqlite3.connect(DB); writer.isolation_level = None
    reader = sqlite3.connect(DB); reader.isolation_level = None
    mode = reader.execute("PRAGMA journal_mode").fetchone()[0]
    print(f"    journal mode: {mode}")
    print(f"    reader before:            {reader.execute(CURRENT_STATE).fetchone()[0]}")

    writer.execute("BEGIN IMMEDIATE")
    writer.execute("INSERT INTO ModerationDecision VALUES (3,1,2,'taken_down','2026-03-01T00:00:00Z')")
    print(f"    writer inside its own tx: {writer.execute(CURRENT_STATE).fetchone()[0]}")
    print(f"    reader while uncommitted: {reader.execute(CURRENT_STATE).fetchone()[0]}")

    third = sqlite3.connect(DB, timeout=0.5); third.isolation_level = None
    try:
        third.execute("INSERT INTO ModerationDecision VALUES (4,1,2,'demoted','2026-03-02T00:00:00Z')")
        print("    third connection write: succeeded")
    except sqlite3.OperationalError as e:
        print(f"    third connection write: {e}")
    third.close()

    writer.execute("COMMIT")
    print(f"    reader after commit:      {reader.execute(CURRENT_STATE).fetchone()[0]}")
    writer.close(); reader.close()
    print()


def t3(con):
    print("T3  a handle changes at most twice in any rolling 365 days")
    con.execute("""
        CREATE TRIGGER trg_handle_rate_limit
        BEFORE INSERT ON HandleChange
        FOR EACH ROW
        WHEN (SELECT count(*) FROM HandleChange h
              WHERE h.user_id = NEW.user_id
                AND h.effective_at > strftime('%Y-%m-%dT%H:%M:%SZ', NEW.effective_at, '-365 days')) >= 3
        BEGIN
            SELECT RAISE(ABORT, 'handle changed twice already in the last 365 days');
        END""")

    for when, handle in [('2026-02-01T00:00:00Z', 'alicia'),
                         ('2026-04-01T00:00:00Z', 'alison'),
                         ('2026-06-01T00:00:00Z', 'alyssa')]:
        try:
            con.execute("BEGIN")
            con.execute("INSERT INTO HandleChange VALUES (1,?,?)", (when, handle))
            con.execute("UPDATE AppUser SET handle=? WHERE user_id=1", (handle,))
            con.execute("COMMIT")
            print(f"    change to {handle}: accepted")
        except sqlite3.IntegrityError as e:
            print(f"    change to {handle}: rejected, {e}")
            con.execute("ROLLBACK")

    handle = con.execute("SELECT handle FROM AppUser WHERE user_id=1").fetchone()[0]
    hist = [r[0] for r in con.execute("SELECT handle FROM HandleChange ORDER BY effective_at")]
    print(f"    handle now: {handle}")
    print(f"    history:    {hist}")
    print(f"    consistent: {handle == hist[-1]}")


con = fresh()
t1(con)
con.close()
t2()
con = sqlite3.connect(DB); con.isolation_level = None
con.execute("PRAGMA foreign_keys = ON")
t3(con)
con.close()
