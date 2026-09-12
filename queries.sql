-- ScrollSense queries, Deliverable F
-- Run against scrollsense.db built by schema.sql and generate_data.py (seed 49).

PRAGMA foreign_keys = ON;

-- F1 · Top 10 audio tracks by distinct videos in the last 7 days.
-- Intent: the window is anchored to the latest upload in the data, not date('now').
-- Expected shape: one row per track, capped at 10; 755 tracks are in use in the window.
SELECT t.track_id,
       t.name,
       t.source_kind,
       count(DISTINCT v.video_id) AS videos
FROM AudioTrack t
JOIN Video v ON v.audio_track_id = t.track_id
WHERE v.uploaded_at >= strftime('%Y-%m-%dT%H:%M:%SZ',
                                (SELECT max(uploaded_at) FROM Video), '-7 days')
GROUP BY t.track_id, t.name, t.source_kind
ORDER BY videos DESC, t.track_id
LIMIT 10;

-- Rows returned: 10    Runtime: 12 ms
-- First rows: track_id | name | source_kind | videos
--   78 | bold biscuit sound | original | 12
--   107 | swift moth sound | original | 12
--   224 | velvet koi sound | original | 11
--   26 | loud gecko sound | original | 10
--   58 | plush waffle sound | original | 10
-- Reading: the busiest sound carries 12 of the 1,872 clips uploaded that week, so no single track dominates at this scale.

-- F2 · Watch hours and completion rate per creator, live clips only.
-- Intent: every creator appears; zero-activity creators show 0, not NULL, not absent.
-- Expected shape: aggregate over an outer join; row count = number of creators (1,250).
WITH current_state AS (
    SELECT d.video_id, d.state
    FROM ModerationDecision d
    JOIN (SELECT video_id, max(decided_at) AS latest
          FROM ModerationDecision
          GROUP BY video_id) m
      ON m.video_id = d.video_id AND m.latest = d.decided_at
),
live_video AS (
    SELECT v.video_id, v.owner_id, v.duration_ms
    FROM Video v
    JOIN current_state c ON c.video_id = v.video_id
    WHERE c.state = 'live'
),
per_impression AS (
    SELECT i.impression_id,
           lv.owner_id,
           sum(s.end_offset_ms - s.start_offset_ms) AS watch_ms,
           max(CASE WHEN s.end_offset_ms >= lv.duration_ms * 0.95 THEN 1 ELSE 0 END) AS completed
    FROM Impression i
    JOIN live_video lv ON lv.video_id = i.video_id
    LEFT JOIN ViewSegment s ON s.impression_id = i.impression_id
    GROUP BY i.impression_id, lv.owner_id
)
SELECT c.user_id AS creator_id,
       count(p.impression_id) AS impressions,
       ROUND(COALESCE(sum(p.watch_ms), 0) / 3600000.0, 3) AS watch_hours,
       ROUND(COALESCE(avg(p.completed), 0), 4) AS mean_completion_rate
FROM Creator c
LEFT JOIN per_impression p ON p.owner_id = c.user_id
GROUP BY c.user_id
ORDER BY watch_hours DESC, creator_id;

-- Rows returned: 1,250    Runtime: 966 ms
-- First rows: creator_id | impressions | watch_hours | mean_completion_rate
--   23 | 9005 | 26.237 | 0.021
--   2283 | 18851 | 22.583 | 0.0186
--   2020 | 15336 | 20.293 | 0.0218
--   4699 | 7139 | 19.722 | 0.0202
--   1683 | 8752 | 19.427 | 0.0194
-- Reading: the top creator holds 26 watch hours against a mean completion rate near 2%, which is the funnel working as the brief describes: most impressions never become views, and few views reach the end.

-- F3 · Videos with no audio track, written with NOT IN.
-- Intent: find every clip whose audio_track_id points at nothing.
-- Expected shape: 3,018 rows, matching the count of NULL audio_track_id values.
SELECT v.video_id, v.caption
FROM Video v
WHERE v.audio_track_id NOT IN (SELECT track_id FROM AudioTrack)
ORDER BY v.video_id;

-- Rows returned: 0    Runtime: 4 ms
-- First rows: none, the result is empty
-- Reading: zero rows, which is wrong. See the note under the NOT EXISTS version.

-- F3 (continued) · The same question, written with NOT EXISTS.
-- Intent: as above.
-- Expected shape: 3,018 rows.
SELECT v.video_id, v.caption
FROM Video v
WHERE NOT EXISTS (SELECT 1 FROM AudioTrack t WHERE t.track_id = v.audio_track_id)
ORDER BY v.video_id;

-- Rows returned: 3,018    Runtime: 5 ms
-- First rows: video_id | caption
--   9 | part 26 of the series #tutorial #viral
--   12 | day 26 of trying
--   39 | part 10 of the series #trending #asmr #prank
--   49 | how it started vs how it ended #howto
--   58 | look at this
-- Reading: 3,018 clips carry no track, which is the correct answer.
-- Difference: NOT IN evaluates audio_track_id NOT IN (list). For a clip with
-- no track that is NULL NOT IN (...), which is NULL rather than true, so the
-- row is not returned and the whole result is empty. NOT EXISTS asks whether a
-- matching AudioTrack row exists; for a NULL key none does, so the row is
-- returned. NOT IN is only safe when both the column and the subquery are
-- known to be free of NULLs.

-- F4 · Users who liked and then retracted a like on the same clip within 60 seconds.
-- Intent: the append-only signal stream makes this a self-join on Signal.
-- Expected shape: one row per like and retraction pair inside the window.
SELECT l.user_id,
       l.video_id,
       l.occurred_at AS liked_at,
       r.occurred_at AS retracted_at,
       CAST((julianday(r.occurred_at) - julianday(l.occurred_at)) * 86400 AS INT) AS seconds_held
FROM Signal l
JOIN Signal r
  ON r.user_id = l.user_id
 AND r.video_id = l.video_id
 AND r.signal_type = 'like_retracted'
 AND r.occurred_at > l.occurred_at
WHERE l.signal_type = 'like'
  AND (julianday(r.occurred_at) - julianday(l.occurred_at)) * 86400 <= 60
ORDER BY seconds_held, l.user_id;

-- Rows returned: 96    Runtime: 2 ms
-- First rows: user_id | video_id | liked_at | retracted_at | seconds_held
--   904 | 9899 | 2026-05-24T19:26:22Z | 2026-05-24T19:26:25Z | 2
--   4354 | 8411 | 2026-07-08T23:16:55Z | 2026-07-08T23:16:58Z | 2
--   1831 | 13792 | 2026-08-30T23:24:42Z | 2026-08-30T23:24:45Z | 3
--   2574 | 3546 | 2026-07-19T16:37:50Z | 2026-07-19T16:37:53Z | 3
--   4368 | 18721 | 2026-05-08T19:03:59Z | 2026-05-08T19:04:03Z | 3
-- Reading: 96 pairs, most within 3 to 20 seconds, which suggests accidental taps.

-- F5 · Videos whose caption carries a given hashtag.
-- Intent: match case-insensitively and tolerate punctuation and surrounding whitespace.
-- Expected shape: one row per matching video.
WITH target(tag) AS (VALUES ('viral'))
SELECT v.video_id, v.caption
FROM Video v, target
WHERE ' ' || replace(replace(replace(replace(replace(lower(trim(v.caption)),
          ',', ' '), '.', ' '), '!', ' '), '?', ' '), '#', ' ') || ' '
      LIKE '% ' || lower(target.tag) || ' %'
ORDER BY v.video_id;

-- Rows returned: 1,935    Runtime: 24 ms
-- First rows: video_id | caption
--   9 | part 26 of the series #tutorial #viral
--   16 | how it started vs how it ended #outfit #viral #duet
--   19 | this took forever #outfit #viral #cover
--   24 | nobody talks about this #howto #viral #trending
--   28 | how it started vs how it ended #outfit #viral #trending
-- Reading: 1,935 of 20,000 clips carry the tag, matching a plain LIKE check on the same data.
-- SQLite has no REGEXP and no split_part, so the caption is lowercased,
-- trimmed, and its punctuation and hash marks replaced with spaces; padding
-- both sides with a space then makes LIKE '% tag %' a whole-word match.
-- LIKE or GLOB: I used LIKE, which is case-insensitive for ASCII. GLOB is
-- case-sensitive and would need lower() on both sides. For a caption in Tamil
-- the answer is the same either way, since Tamil has no case distinction.

-- F6 · Users shown a creator's clips who never engaged with any of them.
-- Intent: set difference between everyone shown a clip and everyone who signalled on one.
-- Expected shape: fewer rows than the count of distinct users shown a clip.
SELECT i.user_id
FROM Impression i
JOIN Video v ON v.video_id = i.video_id
WHERE v.owner_id = 2283
EXCEPT
SELECT s.user_id
FROM Signal s
JOIN Video v ON v.video_id = s.video_id
WHERE v.owner_id = 2283;

-- Rows returned: 3,835    Runtime: 82 ms
-- First rows: user_id
--   1
--   2
--   3
--   4
--   5
-- Reading: 3,835 of the users shown this creator's clips never signalled on any of them, which is the funnel leak the brief describes.

-- F6 (continued) · The same signal roll-up with UNION.
-- Intent: show what UNION does to duplicates.
-- Expected shape: one row per distinct signal type across both arms.
SELECT signal_type FROM Signal WHERE signal_type IN ('like', 'save')
UNION
SELECT signal_type FROM Signal WHERE signal_type IN ('save', 'share');

-- Rows returned: 3    Runtime: 2 ms
-- First rows: signal_type
--   like
--   save
--   share
-- Reading: three rows: like, save, share.

-- F6 (continued) · The same roll-up with UNION ALL.
-- Intent: as above.
-- Expected shape: every row from both arms, kept.
SELECT signal_type FROM Signal WHERE signal_type IN ('like', 'save')
UNION ALL
SELECT signal_type FROM Signal WHERE signal_type IN ('save', 'share');

-- Rows returned: 6,612    Runtime: 3 ms
-- First rows: signal_type
--   like
--   like
--   save
--   like
--   like
-- Reading: 6,612 rows.
-- Difference: UNION removes duplicates across both arms and returns the three
-- distinct signal types. UNION ALL keeps every row, so 6,612 is the sum of
-- both arms including the 'save' rows counted twice, once from each. UNION
-- also has to sort or hash to deduplicate, which UNION ALL does not.

-- F7 · Cost of each agent session last month, by prompt template version.
-- Intent: cost is computed against the price in force at the turn's timestamp, not the current price.
-- Expected shape: one row per session and template version above the threshold.
WITH turn_cost AS (
    SELECT t.session_id,
           t.template_version_id,
           (t.input_tokens * p.input_rate
          + t.output_tokens * p.output_rate
          + t.cached_tokens * p.cached_rate) / 1000.0 AS cost
    FROM Turn t
    JOIN ModelPrice p
      ON p.model_id = t.model_id
     AND t.occurred_at >= p.valid_from
     AND (p.valid_to IS NULL OR t.occurred_at < p.valid_to)
    WHERE t.assistant_message IS NOT NULL
      AND strftime('%Y-%m', t.occurred_at)
          = strftime('%Y-%m', (SELECT max(occurred_at) FROM Turn))
)
SELECT session_id,
       template_version_id,
       count(*) AS turns,
       ROUND(sum(cost), 4) AS cost
FROM turn_cost
GROUP BY session_id, template_version_id
HAVING sum(cost) > 0.05
ORDER BY cost DESC, session_id;

-- Rows returned: 240    Runtime: 4 ms
-- First rows: session_id | template_version_id | turns | cost
--   909 | 36 | 6 | 2.9931
--   243 | 36 | 5 | 2.8352
--   1840 | 36 | 5 | 2.6584
--   350 | 36 | 5 | 2.3779
--   1428 | 36 | 6 | 2.349
-- Reading: 240 session-versions cost more than 0.05, and nearly all run on the newest template version, which is what a template edited several times a week looks like.

-- F8 · Videos whose moderation state changed more than twice, with the full sequence.
-- Intent: the sequence must be in chronological order.
-- Expected shape: one row per video with three or more decisions.
SELECT video_id,
       count(*) AS decisions,
       group_concat(state, ' -> ' ORDER BY decided_at) AS transitions
FROM ModerationDecision
GROUP BY video_id
HAVING count(*) > 2
ORDER BY decisions DESC, video_id;

-- Rows returned: 825    Runtime: 18 ms
-- First rows: video_id | decisions | transitions
--   25 | 3 | pending -> live -> demoted
--   62 | 3 | pending -> live -> live
--   67 | 3 | pending -> live -> live
--   79 | 3 | pending -> live -> demoted
--   90 | 3 | pending -> live -> taken_down
-- Reading: 825 clips have a third decision after the initial pending and live pair, and taken_down and demoted are the common endings.
-- group_concat accepts ORDER BY only from SQLite 3.44; on anything older the
-- output order is undefined and the sequence would look plausible while being
-- wrong. Running 3.53.4 here.

-- F9 · Each user's longest streak of consecutive active days.
-- Intent: a day counts as active if any impression was recorded for that user.
-- Expected shape: one row per user; row count = 5,000.
WITH active AS (
    SELECT DISTINCT user_id, date(shown_at) AS day
    FROM Impression
),
grouped AS (
    SELECT user_id, day,
           julianday(day) - ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY day) AS grp
    FROM active
),
runs AS (
    SELECT user_id, grp, count(*) AS streak, min(day) AS from_day, max(day) AS to_day
    FROM grouped
    GROUP BY user_id, grp
)
SELECT user_id, max(streak) AS longest_streak
FROM runs
GROUP BY user_id
ORDER BY longest_streak DESC, user_id;

-- Rows returned: 5,000    Runtime: 643 ms
-- First rows: user_id | longest_streak
--   597 | 243
--   1082 | 243
--   1099 | 243
--   1270 | 243
--   2293 | 243
-- Reading: nine users were active on all 243 days in the data, and these are the heaviest viewers at up to 34 impressions a day; the rest tail off smoothly.

-- F10 · Creators ranked by 7-day rolling watch time, with week-over-week change.
-- Intent: reported for the most recent day in the data.
-- Expected shape: one row per creator active on that day.
WITH daily AS (
    SELECT v.owner_id AS creator_id,
           date(i.shown_at) AS day,
           sum(s.end_offset_ms - s.start_offset_ms) / 3600000.0 AS hours
    FROM ViewSegment s
    JOIN Impression i ON i.impression_id = s.impression_id
    JOIN Video v ON v.video_id = i.video_id
    GROUP BY v.owner_id, date(i.shown_at)
),
rolling AS (
    SELECT creator_id, day, hours,
           sum(hours) OVER (PARTITION BY creator_id
                            ORDER BY julianday(day)
                            RANGE BETWEEN 6 PRECEDING AND CURRENT ROW) AS hours_7d
    FROM daily
),
wow AS (
    SELECT creator_id, day, hours_7d,
           LAG(hours_7d, 7) OVER (PARTITION BY creator_id ORDER BY julianday(day)) AS prev_7d
    FROM rolling
)
SELECT creator_id,
       day,
       ROUND(hours_7d, 3) AS hours_7d,
       ROUND(hours_7d - prev_7d, 3) AS wow_change,
       RANK() OVER (PARTITION BY day ORDER BY hours_7d DESC) AS rank_on_day
FROM wow
WHERE day = (SELECT max(date(shown_at)) FROM Impression)
ORDER BY rank_on_day;

-- Rows returned: 194    Runtime: 281 ms
-- First rows: creator_id | day | hours_7d | wow_change | rank_on_day
--   23 | 2026-08-31 | 0.743 | -0.126 | 1
--   2020 | 2026-08-31 | 0.639 | 0.083 | 2
--   827 | 2026-08-31 | 0.617 | 0.15 | 3
--   2283 | 2026-08-31 | 0.596 | -0.068 | 4
--   1683 | 2026-08-31 | 0.575 | 0.076 | 5
-- Reading: the leader accumulated 0.74 watch hours over the week and is down 0.13 on the week before, so the top of the table moves around rather than being fixed.
-- "7 days" here means seven calendar days, not the seven days on which this
-- creator happened to have activity. That is what Growth asked for: a creator
-- who posted nothing for three days should show the dip. The RANGE frame over
-- julianday(day) gives calendar days; ROWS BETWEEN 6 PRECEDING would have
-- given the other query, counting only days that have rows.
-- SQLite's RANGE frames take numeric offsets only, so there is no
-- INTERVAL '7 days' and ordering by julianday() is required.

-- F11 · Full nesting tree for one agent session's tool calls, with depth.
-- Intent: session 164, which has the most nested calls in the data.
-- Expected shape: one row per call in the session, ordered so children follow their parent.
WITH RECURSIVE tree AS (
    SELECT c.call_id, c.turn_id, c.tool_name, c.latency_ms, c.errored,
           0 AS depth,
           printf('%08d', c.call_id) AS path
    FROM ToolCall c
    JOIN Turn t ON t.turn_id = c.turn_id
    WHERE t.session_id = 164 AND c.parent_call_id IS NULL
    UNION ALL
    SELECT c.call_id, c.turn_id, c.tool_name, c.latency_ms, c.errored,
           tree.depth + 1,
           tree.path || '.' || printf('%08d', c.call_id)
    FROM ToolCall c
    JOIN tree ON c.parent_call_id = tree.call_id
)
SELECT turn_id,
       depth,
       substr('                ', 1, depth * 2) || tool_name AS call_tree,
       latency_ms,
       errored
FROM tree
ORDER BY path;

-- Rows returned: 12    Runtime: 4 ms
-- First rows: turn_id | depth | call_tree | latency_ms | errored
--   396 | 0 | search_videos | 128 | 0
--   396 | 1 |   fetch_trending_audio | 334 | 0
--   397 | 0 | fetch_trending_audio | 317 | 0
--   397 | 1 |   search_videos | 367 | 0
--   397 | 0 | fetch_trending_audio | 175 | 0
-- Reading: the deepest chain is search_videos calling fetch_trending_audio, and most calls sit at the top level.

-- F12 · Sessions where the agent recommended a clip the user then watched to completion.
-- Intent: report the clip's position in the returned shelf.
-- Expected shape: one row per completed recommendation.
WITH completed AS (
    SELECT i.impression_id,
           i.recommendation_id,
           sum(s.end_offset_ms - s.start_offset_ms) AS watch_ms
    FROM Impression i
    JOIN ViewSegment s ON s.impression_id = i.impression_id
    JOIN Video v ON v.video_id = i.video_id
    WHERE i.recommendation_id IS NOT NULL
    GROUP BY i.impression_id, i.recommendation_id, v.duration_ms
    HAVING max(s.end_offset_ms) >= max(v.duration_ms) * 0.95
)
SELECT t.session_id,
       t.seq AS turn_seq,
       r.position AS shelf_position,
       r.video_id,
       c.watch_ms,
       i.shown_at
FROM completed c
JOIN Recommendation r ON r.recommendation_id = c.recommendation_id
JOIN Turn t ON t.turn_id = r.turn_id
JOIN Impression i ON i.impression_id = c.impression_id
ORDER BY t.session_id, t.seq, r.position;

-- Rows returned: 54    Runtime: 17 ms
-- First rows: session_id | turn_seq | shelf_position | video_id | watch_ms | shown_at
--   17 | 4 | 2 | 9776 | 20139 | 2026-02-27T18:57:20Z
--   35 | 1 | 4 | 14041 | 130950 | 2026-08-13T18:53:03Z
--   56 | 3 | 3 | 7276 | 83578 | 2026-04-21T20:48:00Z
--   89 | 2 | 4 | 12514 | 67453 | 2026-08-31T16:59:27Z
--   103 | 5 | 4 | 12779 | 43497 | 2026-08-07T12:43:52Z
-- Reading: 54 recommendations were watched to the end. Positions 2, 3 and 4 appear as often as position 1, which suggests shelf order is not driving what gets watched.

-- F13 · Turns where the LLM judge scored above 4 but the user gave a thumbs down.
-- Intent: compare the automated score against the human verdict on the same turn.
-- Expected shape: a small set; most turns are never judged and very few are ever rated.
SELECT j.turn_id,
       j.judge_version_id,
       j.helpfulness,
       j.groundedness,
       j.safety,
       u.rating,
       u.rated_at
FROM JudgeScore j
JOIN UserRating u ON u.turn_id = j.turn_id
WHERE j.helpfulness > 4
  AND u.rating = 'down'
  AND u.rated_at = (SELECT max(rated_at) FROM UserRating u2 WHERE u2.turn_id = j.turn_id)
ORDER BY j.helpfulness DESC, j.turn_id;

-- Rows returned: 6    Runtime: 0 ms
-- First rows: turn_id | judge_version_id | helpfulness | groundedness | safety | rating | rated_at
--   1765 | 1 | 4.64 | 4.18 | 4.81 | down | 2026-06-17T19:29:10Z
--   2725 | 1 | 4.47 | 3.77 | 4.59 | down | 2026-05-06T17:49:02Z
--   3529 | 3 | 4.29 | 3.1 | 4.83 | down | 2026-04-11T20:07:37Z
--   4278 | 1 | 4.28 | 4.26 | 4.6 | down | 2026-06-02T21:44:50Z
--   1784 | 1 | 4.12 | 2.37 | 4.33 | down | 2026-02-28T00:16:18Z
-- Reading: six turns where the judge was confident and the user disagreed.
-- Why this set is the most commercially valuable data in the company: it is
-- the only direct evidence of where the automated quality metric is wrong.
-- Every dashboard, regression test and prompt iteration is scored by the
-- judge, so a judge that is confidently wrong makes the whole quality process
-- lie in the same direction without anyone noticing. These rows are labelled
-- counterexamples that can be used to retrain the judge, and they are cheap to
-- collect because the user volunteered the label.

