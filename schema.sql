-- ScrollSense schema, SQLite 3.53.4

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;


-- Lookup tables

CREATE TABLE ModerationState (
    state TEXT PRIMARY KEY,
    shows_in_feed INTEGER NOT NULL CHECK (shows_in_feed IN (0, 1)),
    visible INTEGER NOT NULL CHECK (visible IN (0, 1))
);

CREATE TABLE CreatorTier (
    tier TEXT PRIMARY KEY,
    revenue_share REAL NOT NULL CHECK (revenue_share BETWEEN 0 AND 1),
    rank INTEGER NOT NULL UNIQUE
);

CREATE TABLE ShareDestination (
    destination TEXT PRIMARY KEY,
    is_external INTEGER NOT NULL CHECK (is_external IN (0, 1))
);

CREATE TABLE InterestCategory (
    category_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);


-- Users

CREATE TABLE AppUser (
    user_id INTEGER PRIMARY KEY,
    handle TEXT NOT NULL,
    display_name TEXT NOT NULL,
    phone TEXT,
    email TEXT,
    account_state TEXT NOT NULL CHECK (account_state IN ('active', 'deactivated', 'pending_deletion')),
    created_at TEXT NOT NULL,
    deletion_requested_at TEXT,

    CHECK (handle = trim(handle) AND length(handle) BETWEEN 3 AND 30),
    CHECK (phone IS NOT NULL OR email IS NOT NULL),
    CHECK ((account_state = 'pending_deletion') = (deletion_requested_at IS NOT NULL))
);

CREATE UNIQUE INDEX ux_appuser_handle ON AppUser (handle COLLATE NOCASE);

CREATE TABLE HandleChange (
    user_id INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    effective_at TEXT NOT NULL,
    handle TEXT NOT NULL,

    PRIMARY KEY (user_id, effective_at)
);

CREATE TABLE DeclaredInterest (
    user_id INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    category_id INTEGER NOT NULL REFERENCES InterestCategory(category_id) ON DELETE RESTRICT,
    declared_at TEXT NOT NULL,

    PRIMARY KEY (user_id, category_id)
);

CREATE TABLE InferredInterest (
    user_id INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    category_id INTEGER NOT NULL REFERENCES InterestCategory(category_id) ON DELETE RESTRICT,
    valid_from TEXT NOT NULL,
    valid_to TEXT,
    confidence REAL NOT NULL CHECK (confidence BETWEEN 0 AND 1),

    PRIMARY KEY (user_id, category_id, valid_from),
    CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE TABLE InterestSuppression (
    user_id INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    category_id INTEGER NOT NULL REFERENCES InterestCategory(category_id) ON DELETE RESTRICT,
    suppressed_at TEXT NOT NULL,

    PRIMARY KEY (user_id, category_id)
);

CREATE TABLE Follow (
    follower_id INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE RESTRICT,
    followee_id INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE RESTRICT,
    started_at TEXT NOT NULL,
    ended_at TEXT,
    end_reason TEXT CHECK (end_reason IN ('unfollowed', 'blocked')),

    PRIMARY KEY (follower_id, followee_id, started_at),
    CHECK (follower_id <> followee_id),
    CHECK (ended_at IS NULL OR ended_at > started_at),
    CHECK ((ended_at IS NULL) = (end_reason IS NULL))
);

CREATE TABLE Block (
    blocker_id INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    blocked_id INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    started_at TEXT NOT NULL,
    ended_at TEXT,

    PRIMARY KEY (blocker_id, blocked_id, started_at),
    CHECK (blocker_id <> blocked_id),
    CHECK (ended_at IS NULL OR ended_at > started_at)
);

CREATE TABLE Mute (
    muter_id INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    muted_id INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    started_at TEXT NOT NULL,
    ended_at TEXT,

    PRIMARY KEY (muter_id, muted_id, started_at),
    CHECK (muter_id <> muted_id),
    CHECK (ended_at IS NULL OR ended_at > started_at)
);


-- Content

CREATE TABLE Creator (
    user_id INTEGER PRIMARY KEY REFERENCES AppUser(user_id) ON DELETE CASCADE,
    became_creator_at TEXT NOT NULL
);

CREATE TABLE CreatorTierPeriod (
    user_id INTEGER NOT NULL REFERENCES Creator(user_id) ON DELETE CASCADE,
    valid_from TEXT NOT NULL,
    valid_to TEXT,
    tier TEXT NOT NULL REFERENCES CreatorTier(tier) ON DELETE RESTRICT,

    PRIMARY KEY (user_id, valid_from),
    CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE TABLE AudioTrack (
    track_id INTEGER PRIMARY KEY,
    origin_video_id INTEGER REFERENCES Video(video_id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
    name TEXT NOT NULL,
    source_kind TEXT NOT NULL CHECK (source_kind IN ('original', 'licensed')),

    CHECK (source_kind = 'original' OR origin_video_id IS NULL)
);

CREATE TABLE Video (
    video_id INTEGER PRIMARY KEY,
    owner_id INTEGER NOT NULL REFERENCES Creator(user_id) ON DELETE RESTRICT,
    audio_track_id INTEGER REFERENCES AudioTrack(track_id) ON DELETE SET NULL,
    duration_ms INTEGER NOT NULL CHECK (duration_ms BETWEEN 20000 AND 90000),
    caption TEXT CHECK (caption IS NULL OR length(caption) <= 2200),
    uploaded_at TEXT NOT NULL
);

CREATE TABLE Hashtag (
    hashtag_id INTEGER PRIMARY KEY,
    tag TEXT NOT NULL UNIQUE,

    CHECK (tag = lower(trim(tag)) AND tag NOT LIKE '#%')
);

CREATE TABLE VideoHashtag (
    video_id INTEGER NOT NULL REFERENCES Video(video_id) ON DELETE CASCADE,
    hashtag_id INTEGER NOT NULL REFERENCES Hashtag(hashtag_id) ON DELETE RESTRICT,

    PRIMARY KEY (video_id, hashtag_id)
);

CREATE TABLE Reviewer (
    reviewer_id INTEGER PRIMARY KEY,
    reviewer_kind TEXT NOT NULL CHECK (reviewer_kind IN ('human', 'classifier')),
    name TEXT NOT NULL
);

CREATE TABLE ModerationDecision (
    decision_id INTEGER PRIMARY KEY,
    video_id INTEGER NOT NULL REFERENCES Video(video_id) ON DELETE CASCADE,
    reviewer_id INTEGER NOT NULL REFERENCES Reviewer(reviewer_id) ON DELETE RESTRICT,
    state TEXT NOT NULL REFERENCES ModerationState(state) ON DELETE RESTRICT,
    decided_at TEXT NOT NULL,

    UNIQUE (video_id, decided_at)
);


-- Agent

CREATE TABLE PromptTemplate (
    template_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE PromptTemplateVersion (
    template_version_id INTEGER PRIMARY KEY,
    template_id INTEGER NOT NULL REFERENCES PromptTemplate(template_id) ON DELETE RESTRICT,
    version_no INTEGER NOT NULL CHECK (version_no >= 1),
    body TEXT NOT NULL,
    created_at TEXT NOT NULL,

    UNIQUE (template_id, version_no)
);

CREATE TABLE Model (
    model_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE ModelPrice (
    model_id INTEGER NOT NULL REFERENCES Model(model_id) ON DELETE RESTRICT,
    valid_from TEXT NOT NULL,
    valid_to TEXT,
    input_rate REAL NOT NULL CHECK (input_rate >= 0),
    output_rate REAL NOT NULL CHECK (output_rate >= 0),
    cached_rate REAL NOT NULL CHECK (cached_rate >= 0),

    PRIMARY KEY (model_id, valid_from),
    CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE TABLE JudgeVersion (
    judge_version_id INTEGER PRIMARY KEY,
    model_id INTEGER NOT NULL REFERENCES Model(model_id) ON DELETE RESTRICT,
    scoring_prompt_version INTEGER NOT NULL CHECK (scoring_prompt_version >= 1),

    UNIQUE (model_id, scoring_prompt_version)
);

CREATE TABLE AgentSession (
    session_id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE RESTRICT,
    started_at TEXT NOT NULL
);

CREATE TABLE Turn (
    turn_id INTEGER PRIMARY KEY,
    session_id INTEGER NOT NULL REFERENCES AgentSession(session_id) ON DELETE CASCADE,
    seq INTEGER NOT NULL CHECK (seq >= 1),
    template_version_id INTEGER REFERENCES PromptTemplateVersion(template_version_id) ON DELETE RESTRICT,
    model_id INTEGER REFERENCES Model(model_id) ON DELETE RESTRICT,
    user_message TEXT NOT NULL,
    assistant_message TEXT,
    temperature REAL CHECK (temperature IS NULL OR temperature BETWEEN 0 AND 2),
    input_tokens INTEGER CHECK (input_tokens IS NULL OR input_tokens >= 0),
    output_tokens INTEGER CHECK (output_tokens IS NULL OR output_tokens >= 0),
    cached_tokens INTEGER CHECK (cached_tokens IS NULL OR cached_tokens >= 0),
    occurred_at TEXT NOT NULL,

    UNIQUE (session_id, seq),
    CHECK ((assistant_message IS NULL) = (template_version_id IS NULL)),
    CHECK ((assistant_message IS NULL) = (model_id IS NULL)),
    CHECK ((assistant_message IS NULL) = (temperature IS NULL)),
    CHECK ((assistant_message IS NULL) = (input_tokens IS NULL))
);

CREATE TABLE ToolCall (
    call_id INTEGER PRIMARY KEY,
    turn_id INTEGER NOT NULL REFERENCES Turn(turn_id) ON DELETE CASCADE,
    call_seq INTEGER NOT NULL CHECK (call_seq >= 1),
    parent_call_id INTEGER REFERENCES ToolCall(call_id) ON DELETE CASCADE,
    tool_name TEXT NOT NULL CHECK (tool_name IN ('search_videos', 'get_user_history', 'fetch_trending_audio')),
    args_json TEXT NOT NULL CHECK (json_valid(args_json)),
    result TEXT,
    latency_ms INTEGER NOT NULL CHECK (latency_ms >= 0),
    errored INTEGER NOT NULL CHECK (errored IN (0, 1)),

    UNIQUE (turn_id, call_seq),
    CHECK (parent_call_id IS NULL OR parent_call_id <> call_id),
    CHECK ((errored = 1) = (result IS NULL))
);

CREATE TABLE Recommendation (
    recommendation_id INTEGER PRIMARY KEY,
    turn_id INTEGER NOT NULL REFERENCES Turn(turn_id) ON DELETE CASCADE,
    position INTEGER NOT NULL CHECK (position >= 1),
    video_id INTEGER NOT NULL REFERENCES Video(video_id) ON DELETE CASCADE,

    UNIQUE (turn_id, position)
);

CREATE TABLE JudgeScore (
    turn_id INTEGER NOT NULL REFERENCES Turn(turn_id) ON DELETE CASCADE,
    judge_version_id INTEGER NOT NULL REFERENCES JudgeVersion(judge_version_id) ON DELETE RESTRICT,
    helpfulness REAL NOT NULL CHECK (helpfulness BETWEEN 1 AND 5),
    groundedness REAL NOT NULL CHECK (groundedness BETWEEN 1 AND 5),
    safety REAL NOT NULL CHECK (safety BETWEEN 1 AND 5),
    scored_at TEXT NOT NULL,

    PRIMARY KEY (turn_id, judge_version_id)
);

CREATE TABLE UserRating (
    turn_id INTEGER NOT NULL REFERENCES Turn(turn_id) ON DELETE CASCADE,
    rated_at TEXT NOT NULL,
    rating TEXT NOT NULL CHECK (rating IN ('up', 'down')),

    PRIMARY KEY (turn_id, rated_at)
);


-- Telemetry

CREATE TABLE Impression (
    impression_id INTEGER PRIMARY KEY,
    video_id INTEGER NOT NULL REFERENCES Video(video_id) ON DELETE CASCADE,
    user_id INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE RESTRICT,
    recommendation_id INTEGER REFERENCES Recommendation(recommendation_id) ON DELETE SET NULL,
    shown_at TEXT NOT NULL,
    feed_position INTEGER NOT NULL CHECK (feed_position >= 0),
    model_version TEXT NOT NULL
);

CREATE TABLE ViewSegment (
    impression_id INTEGER NOT NULL REFERENCES Impression(impression_id) ON DELETE CASCADE,
    started_at TEXT NOT NULL,
    ended_at TEXT NOT NULL,
    start_offset_ms INTEGER NOT NULL CHECK (start_offset_ms >= 0),
    end_offset_ms INTEGER NOT NULL,

    PRIMARY KEY (impression_id, started_at),
    CHECK (ended_at > started_at),
    CHECK (end_offset_ms > start_offset_ms)
);

CREATE TABLE Signal (
    signal_id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE RESTRICT,
    video_id INTEGER NOT NULL REFERENCES Video(video_id) ON DELETE CASCADE,
    signal_type TEXT NOT NULL CHECK (signal_type IN ('like', 'like_retracted', 'save', 'share',
        'comment', 'follow_from_feed', 'not_interested', 'report')),
    occurred_at TEXT NOT NULL
);

CREATE TABLE ShareDetail (
    signal_id INTEGER PRIMARY KEY REFERENCES Signal(signal_id) ON DELETE CASCADE,
    destination TEXT NOT NULL REFERENCES ShareDestination(destination) ON DELETE RESTRICT
);


-- Lookup data

INSERT INTO ModerationState (state, shows_in_feed, visible) VALUES
    ('pending', 0, 0),
    ('live', 1, 1),
    ('age_restricted', 1, 1),
    ('demoted', 1, 1),
    ('taken_down', 0, 0);

INSERT INTO CreatorTier (tier, revenue_share, rank) VALUES
    ('none', 0.00, 1),
    ('basic', 0.30, 2),
    ('partner', 0.55, 3);

INSERT INTO ShareDestination (destination, is_external) VALUES
    ('whatsapp', 1),
    ('instagram', 1),
    ('copied_link', 0);
