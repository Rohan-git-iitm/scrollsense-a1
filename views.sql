-- ScrollSense views, Deliverable G
-- One view per consumer named in section 2.6 of the brief.


-- Mobile client: public profile.
CREATE VIEW v_public_profile AS
SELECT u.user_id,
       u.handle,
       u.display_name,
       (SELECT count(*)
        FROM Follow f
        WHERE f.followee_id = u.user_id
          AND f.ended_at IS NULL) AS follower_count
FROM AppUser u
WHERE u.account_state = 'active';


-- Trust and Safety: current moderation state of every video.
CREATE VIEW v_video_current_state AS
SELECT v.video_id,
       d.state,
       d.decided_at,
       d.reviewer_id
FROM Video v
JOIN ModerationDecision d ON d.video_id = v.video_id
WHERE d.decided_at = (SELECT max(d2.decided_at)
                      FROM ModerationDecision d2
                      WHERE d2.video_id = v.video_id);


-- Growth: each creator's tier as of now.
CREATE VIEW v_creator_tier_current AS
SELECT c.user_id AS creator_id,
       p.tier,
       p.valid_from
FROM Creator c
JOIN CreatorTierPeriod p ON p.user_id = c.user_id
WHERE p.valid_to IS NULL;


-- Growth analysts: per video per day.
CREATE VIEW v_video_daily_engagement AS
WITH imp AS (
    SELECT video_id,
           date(shown_at) AS day,
           count(*) AS impressions
    FROM Impression
    GROUP BY video_id, date(shown_at)
),
views AS (
    SELECT i.video_id,
           date(i.shown_at) AS day,
           count(DISTINCT s.impression_id) AS views,
           sum(s.end_offset_ms - s.start_offset_ms) / 1000.0 AS watch_seconds
    FROM ViewSegment s
    JOIN Impression i ON i.impression_id = s.impression_id
    GROUP BY i.video_id, date(i.shown_at)
),
likes AS (
    SELECT video_id,
           date(occurred_at) AS day,
           sum(CASE WHEN signal_type = 'like' THEN 1 ELSE 0 END)
         - sum(CASE WHEN signal_type = 'like_retracted' THEN 1 ELSE 0 END) AS net_likes
    FROM Signal
    WHERE signal_type IN ('like', 'like_retracted')
    GROUP BY video_id, date(occurred_at)
)
SELECT imp.video_id,
       imp.day,
       imp.impressions,
       COALESCE(views.views, 0) AS views,
       COALESCE(views.watch_seconds, 0) AS watch_seconds,
       COALESCE(likes.net_likes, 0) AS net_likes
FROM imp
LEFT JOIN views ON views.video_id = imp.video_id AND views.day = imp.day
LEFT JOIN likes ON likes.video_id = imp.video_id AND likes.day = imp.day;


-- Finance: cost per turn at the price in force when the turn happened.
CREATE VIEW v_turn_cost AS
SELECT t.turn_id,
       t.session_id,
       t.occurred_at,
       t.model_id,
       t.input_tokens,
       t.output_tokens,
       t.cached_tokens,
       (t.input_tokens * p.input_rate
      + t.output_tokens * p.output_rate
      + t.cached_tokens * p.cached_rate) / 1000.0 AS cost
FROM Turn t
JOIN ModelPrice p
  ON p.model_id = t.model_id
 AND t.occurred_at >= p.valid_from
 AND (p.valid_to IS NULL OR t.occurred_at < p.valid_to)
WHERE t.assistant_message IS NOT NULL;
