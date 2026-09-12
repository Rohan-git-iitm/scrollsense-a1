-- ScrollSense transactions, Deliverable G.3
-- Each script demonstrates a failure mode from section 2.7 of the brief.
-- T2 and T3 need two connections; run_transactions.py drives them.

-- Note on injecting failures: SQLite returns NULL for 1/0 rather than raising,
-- so SELECT 1/0 would let the transaction commit and prove nothing. Each script
-- below injects a statement that violates a real constraint instead.


-- T1. A block must break follows in both directions, atomically.
--
-- The task sheet describes T1 as a like retraction: end the like row, write a
-- negative-signal row, and show a failure between them leaves neither. That
-- does not apply here, because of the assumption made in A4. Likes and
-- retractions are one append-only stream, so a retraction is a single insert
-- and there is no second write to fail after. T1 therefore runs on the
-- operation that is two writes for one action: since we assumed in A12 that a
-- block ends any follows in both directions, blocking inserts a Block row and
-- updates the Follow rows. The retraction is shown below it as a single
-- insert, for contrast.

BEGIN;
    INSERT INTO Block VALUES (1, 2, '2026-03-01T00:00:00Z', NULL);

    UPDATE Follow
    SET ended_at = '2026-03-01T00:00:00Z', end_reason = 'blocked'
    WHERE ended_at IS NULL
      AND ((follower_id = 1 AND followee_id = 2)
        OR (follower_id = 2 AND followee_id = 1));

    -- deliberate failure: a self-block, rejected by CHECK (blocker_id <> blocked_id)
    INSERT INTO Block VALUES (1, 1, '2026-03-01T00:00:00Z', NULL);
COMMIT;

-- Proof of consistency: expect 2 open follows and 0 blocks, as before the attempt.
SELECT (SELECT count(*) FROM Follow WHERE ended_at IS NULL) AS open_follows,
       (SELECT count(*) FROM Block) AS blocks;

-- The retraction, for contrast: one write, so no transaction is needed. The
-- current state is read as the latest signal for that user and clip.
INSERT INTO Signal VALUES (2, 2, 1, 'like_retracted', '2026-03-02T10:00:30Z');

SELECT signal_type
FROM Signal
WHERE user_id = 2 AND video_id = 1
  AND signal_type IN ('like', 'like_retracted')
ORDER BY occurred_at DESC
LIMIT 1;


-- T2. A moderation decision must not be visible before it commits.
-- Connection A:

BEGIN IMMEDIATE;
    INSERT INTO ModerationDecision VALUES (3, 1, 2, 'taken_down', '2026-03-01T00:00:00Z');
-- leave uncommitted here

-- Connection B, while A is still open, sees the old state:
SELECT state
FROM ModerationDecision
WHERE video_id = 1
ORDER BY decided_at DESC
LIMIT 1;
-- returns 'live'

-- Connection C, while A is still open, attempts a write:
INSERT INTO ModerationDecision VALUES (4, 1, 2, 'demoted', '2026-03-02T00:00:00Z');
-- SQLITE_BUSY: database is locked

-- Connection A:
COMMIT;

-- Connection B now sees 'taken_down'.


-- T3. A handle changes at most twice in any rolling 365 days.
-- The rule counts history, so it is enforced by a trigger rather than a CHECK.

CREATE TRIGGER trg_handle_rate_limit
BEFORE INSERT ON HandleChange
FOR EACH ROW
WHEN (SELECT count(*) FROM HandleChange h
      WHERE h.user_id = NEW.user_id
        AND h.effective_at > strftime('%Y-%m-%dT%H:%M:%SZ', NEW.effective_at, '-365 days')) >= 3
BEGIN
    SELECT RAISE(ABORT, 'handle changed twice already in the last 365 days');
END;

BEGIN;
    INSERT INTO HandleChange VALUES (1, '2026-02-01T00:00:00Z', 'alicia');
    UPDATE AppUser SET handle = 'alicia' WHERE user_id = 1;
COMMIT;

BEGIN;
    INSERT INTO HandleChange VALUES (1, '2026-04-01T00:00:00Z', 'alison');
    UPDATE AppUser SET handle = 'alison' WHERE user_id = 1;
COMMIT;

BEGIN;
    INSERT INTO HandleChange VALUES (1, '2026-06-01T00:00:00Z', 'alyssa');
    UPDATE AppUser SET handle = 'alyssa' WHERE user_id = 1;
COMMIT;
-- the third attempt aborts

-- Proof of consistency: the handle is still 'alison' and the history has three
-- rows, so the rejected change left nothing behind.
SELECT (SELECT handle FROM AppUser WHERE user_id = 1) AS current_handle,
       (SELECT count(*) FROM HandleChange WHERE user_id = 1) AS changes_recorded;
