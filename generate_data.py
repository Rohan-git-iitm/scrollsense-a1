#!/usr/bin/env python3
"""Generate seeded sample data for the ScrollSense database."""

import json
import math
import random
import sqlite3
from datetime import datetime, timedelta

# Parameters
SEED = 49
N_USERS = 5_000
N_VIDEOS = 20_000
N_IMPRESSIONS = 300_000
N_AGENT_SESSIONS = 2_000
SCALE = 1

N_CATEGORIES = 30
N_HASHTAGS = 800
N_TRACKS = 2_000
N_REVIEWERS = 40

DB_PATH = "scrollsense.db"
START = datetime(2026, 1, 1)
END = datetime(2026, 9, 1)

N_USERS *= SCALE
N_VIDEOS *= SCALE
N_IMPRESSIONS *= SCALE
N_AGENT_SESSIONS *= SCALE

random.seed(SEED)

SPAN_DAYS = (END - START).days
HOUR_WEIGHTS = [2, 1, 1, 1, 1, 2, 4, 6, 7, 6, 5, 6,
                7, 6, 5, 6, 8, 11, 14, 17, 18, 15, 9, 4]


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def random_time(start=START, end=END):
    """A timestamp weighted toward evenings."""
    day = start + timedelta(days=random.randint(0, max((end - start).days - 1, 0)))
    hour = random.choices(range(24), weights=HOUR_WEIGHTS)[0]
    return day + timedelta(hours=hour, minutes=random.randint(0, 59),
                           seconds=random.randint(0, 59))


def power_law(n, alpha=1.6, cap=None):
    """n draws from a Pareto distribution."""
    out = []
    for _ in range(n):
        v = int(random.paretovariate(alpha))
        out.append(min(v, cap) if cap else v)
    return out


ADJ = ["quiet", "loud", "tiny", "cosmic", "salty", "brisk", "amber", "velvet",
       "lucky", "rusty", "mellow", "sharp", "hazy", "bold", "plush", "swift"]
NOUN = ["otter", "pixel", "mango", "comet", "toast", "ferret", "cactus", "lantern",
        "puffin", "ember", "waffle", "gecko", "orbit", "biscuit", "moth", "koi"]
CATEGORIES = ["cooking", "gaming", "music", "fitness", "dance", "comedy", "study",
              "travel", "fashion", "pets", "art", "diy", "cars", "football",
              "cricket", "photography", "beauty", "tech", "books", "film",
              "anime", "skincare", "coding", "hiking", "coffee", "plants",
              "memes", "science", "history", "languages"]
TAG_WORDS = ["fyp", "viral", "trending", "howto", "vlog", "asmr", "duet", "hack",
             "recipe", "workout", "outfit", "review", "tutorial", "cover", "prank"]
CAPTIONS = ["look at this", "had to share", "part {} of the series", "nobody talks about this",
            "day {} of trying", "this took forever", "not what i expected",
            "how it started vs how it ended", "quick one today", "finally got it right"]
TOOLS = ["search_videos", "get_user_history", "fetch_trending_audio"]
SIGNALS = ["like", "save", "share", "comment", "follow_from_feed", "not_interested", "report"]
SIGNAL_WEIGHTS = [50, 15, 10, 12, 6, 5, 2]

con = sqlite3.connect(DB_PATH)
con.execute("PRAGMA foreign_keys = ON")
cur = con.cursor()
cur.execute("BEGIN")

# Interest categories
cur.executemany("INSERT INTO InterestCategory VALUES (?, ?)",
                [(i + 1, CATEGORIES[i]) for i in range(N_CATEGORIES)])

# Users
users, handle_changes = [], []
seen_handles = set()
user_created = {}

for uid in range(1, N_USERS + 1):
    while True:
        h = f"{random.choice(ADJ)}_{random.choice(NOUN)}{random.randint(1, 9999)}"
        if h.lower() not in seen_handles:
            seen_handles.add(h.lower())
            break

    created = random_time(START, END - timedelta(days=30))
    user_created[uid] = created

    r = random.random()
    if r < 0.92:
        state, deleted_at = "active", None
    elif r < 0.98:
        state, deleted_at = "deactivated", None
    else:
        state = "pending_deletion"
        deleted_at = iso(random_time(END - timedelta(days=30), END))

    if random.random() < 0.7:
        phone, email = f"+91{random.randint(7000000000, 9999999999)}", None
    else:
        phone, email = None, f"{h}@example.com"

    users.append((uid, h, h.replace("_", " ").title(), phone, email,
                  state, iso(created), deleted_at))
    handle_changes.append((uid, iso(created), h))

    # some users have changed handle
    if random.random() < 0.08:
        later = created + timedelta(days=random.randint(30, 180))
        if later < END:
            while True:
                h2 = f"{random.choice(ADJ)}_{random.choice(NOUN)}{random.randint(1, 9999)}"
                if h2.lower() not in seen_handles:
                    seen_handles.add(h2.lower())
                    break
            handle_changes.append((uid, iso(later), h2))

cur.executemany("INSERT INTO AppUser VALUES (?,?,?,?,?,?,?,?)", users)
cur.executemany("INSERT INTO HandleChange VALUES (?,?,?)", handle_changes)

# Interests
declared, inferred, suppressed = [], [], []
for uid in range(1, N_USERS + 1):
    base = user_created[uid]
    declared_cats = random.sample(range(1, N_CATEGORIES + 1), random.randint(1, 5))
    for cid in declared_cats:
        declared.append((uid, cid, iso(base)))

    # weekly refresh closes the old interval and opens a new one
    for cid in random.sample(range(1, N_CATEGORIES + 1), random.randint(0, 6)):
        start = base
        for w in range(random.randint(1, 4)):
            nxt = start + timedelta(days=7)
            last = nxt >= END
            inferred.append((uid, cid, iso(start), None if last else iso(nxt),
                             round(random.betavariate(2, 3), 3)))
            if last:
                break
            start = nxt
    if random.random() < 0.05:
        cid = random.choice(declared_cats)
        suppressed.append((uid, cid, iso(base + timedelta(days=random.randint(1, 60)))))

cur.executemany("INSERT INTO DeclaredInterest VALUES (?,?,?)", declared)
cur.executemany("INSERT INTO InferredInterest VALUES (?,?,?,?,?)", inferred)
cur.executemany("INSERT INTO InterestSuppression VALUES (?,?,?)", suppressed)

# Creators
creator_ids = sorted(random.sample(range(1, N_USERS + 1), int(N_USERS * 0.25)))
creators, tier_periods = [], []
for uid in creator_ids:
    became = user_created[uid] + timedelta(days=random.randint(0, 30))
    if became >= END:
        became = user_created[uid]
    creators.append((uid, iso(became)))

    # some creators move up a tier
    tiers = ["none"]
    if random.random() < 0.25:
        tiers.append("basic")
        if random.random() < 0.3:
            tiers.append("partner")

    at = became
    for i, t in enumerate(tiers):
        nxt = at + timedelta(days=random.randint(40, 90))
        last = (i == len(tiers) - 1) or nxt >= END
        tier_periods.append((uid, iso(at), None if last else iso(nxt), t))
        if last:
            break
        at = nxt

cur.executemany("INSERT INTO Creator VALUES (?,?)", creators)
cur.executemany("INSERT INTO CreatorTierPeriod VALUES (?,?,?,?)", tier_periods)

# Audio tracks; origin set after videos exist
tracks = []
for tid in range(1, N_TRACKS + 1):
    kind = "original" if random.random() < 0.6 else "licensed"
    tracks.append((tid, None, f"{random.choice(ADJ)} {random.choice(NOUN)} sound", kind))
cur.executemany("INSERT INTO AudioTrack VALUES (?,?,?,?)", tracks)
original_tracks = [t[0] for t in tracks if t[3] == "original"]

# Videos
# clips per creator follow a power law
weights = power_law(len(creator_ids), alpha=1.5, cap=400)
owners = random.choices(creator_ids, weights=weights, k=N_VIDEOS)

became_at = {c[0]: datetime.strptime(c[1], "%Y-%m-%dT%H:%M:%SZ") for c in creators}

videos = []
for vid in range(1, N_VIDEOS + 1):
    owner = owners[vid - 1]
    uploaded = random_time(became_at[owner], END)
    # trending sounds carry most clips
    if random.random() < 0.85:
        track = random.choice(original_tracks[:200]) if random.random() < 0.6 \
            else random.randint(1, N_TRACKS)
    else:
        track = None
    caption = random.choice(CAPTIONS).format(random.randint(1, 30))
    if random.random() < 0.75:
        caption += " " + " ".join("#" + random.choice(TAG_WORDS)
                                  for _ in range(random.randint(1, 3)))
    videos.append((vid, owner, track, random.randint(20000, 90000), caption, iso(uploaded)))

cur.executemany("INSERT INTO Video VALUES (?,?,?,?,?,?)", videos)

# an original track came from one of its clips
cur.executemany(
    "UPDATE AudioTrack SET origin_video_id = ? WHERE track_id = ?",
    [(random.randint(1, N_VIDEOS), t) for t in original_tracks])

# Hashtags
hashtags = []
seen_tags = set()
while len(hashtags) < N_HASHTAGS:
    t = random.choice(TAG_WORDS) + str(random.randint(1, 400))
    if t not in seen_tags:
        seen_tags.add(t)
        hashtags.append((len(hashtags) + 1, t))
cur.executemany("INSERT INTO Hashtag VALUES (?,?)", hashtags)

video_hashtags = set()
for vid in range(1, N_VIDEOS + 1):
    for _ in range(random.randint(0, 4)):
        video_hashtags.add((vid, random.randint(1, N_HASHTAGS)))
cur.executemany("INSERT INTO VideoHashtag VALUES (?,?)", sorted(video_hashtags))

# Moderation
reviewers = [(1, "classifier", "auto-mod-v3")]
for i in range(2, N_REVIEWERS + 1):
    reviewers.append((i, "human", f"reviewer_{i:02d}"))
cur.executemany("INSERT INTO Reviewer VALUES (?,?,?)", reviewers)

decisions = []
did = 0
for vid in range(1, N_VIDEOS + 1):
    at = datetime.strptime(videos[vid - 1][5], "%Y-%m-%dT%H:%M:%SZ")
    did += 1
    decisions.append((did, vid, 1, "pending", iso(at)))

    at += timedelta(seconds=random.randint(20, 600))
    r = random.random()
    first = "live" if r < 0.93 else ("age_restricted" if r < 0.97 else "demoted")
    did += 1
    decisions.append((did, vid, 1, first, iso(at)))

    if random.random() < 0.06:
        at += timedelta(days=random.randint(1, 60))
        if at < END:
            did += 1
            decisions.append((did, vid, random.randint(2, N_REVIEWERS),
                              random.choice(["taken_down", "demoted", "live"]), iso(at)))
cur.executemany("INSERT INTO ModerationDecision VALUES (?,?,?,?,?)", decisions)

# Social graph
# follower counts follow a power law
follow_weights = power_law(N_USERS, alpha=1.4, cap=3000)
followees = random.choices(range(1, N_USERS + 1), weights=follow_weights,
                           k=int(N_USERS * 12))
follows = {}
for followee in followees:
    follower = random.randint(1, N_USERS)
    if follower == followee:
        continue
    started = random_time()
    key = (follower, followee)
    if key in follows:
        continue
    if random.random() < 0.08:
        ended = started + timedelta(days=random.randint(1, 120))
        if ended < END:
            follows[key] = (follower, followee, iso(started), iso(ended),
                            random.choice(["unfollowed", "blocked"]))
            continue
    follows[key] = (follower, followee, iso(started), None, None)
cur.executemany("INSERT INTO Follow VALUES (?,?,?,?,?)", list(follows.values()))

blocks, mutes = {}, {}
for _ in range(int(N_USERS * 0.4)):
    a, b = random.randint(1, N_USERS), random.randint(1, N_USERS)
    if a == b or (a, b) in blocks:
        continue
    started = random_time()
    ended = None
    if random.random() < 0.2:
        e = started + timedelta(days=random.randint(1, 90))
        ended = iso(e) if e < END else None
    blocks[(a, b)] = (a, b, iso(started), ended)
for _ in range(int(N_USERS * 0.6)):
    a, b = random.randint(1, N_USERS), random.randint(1, N_USERS)
    if a == b or (a, b) in mutes:
        continue
    started = random_time()
    mutes[(a, b)] = (a, b, iso(started), None)
cur.executemany("INSERT INTO Block VALUES (?,?,?,?)", list(blocks.values()))
cur.executemany("INSERT INTO Mute VALUES (?,?,?,?)", list(mutes.values()))

# Models, prices, templates, judges
models = [(1, "gpt-4o-mini"), (2, "llama-3.1-70b"), (3, "scrollsense-ft-v2")]
cur.executemany("INSERT INTO Model VALUES (?,?)", models)

prices = []
for mid, _ in models:
    at = START
    base = random.uniform(0.10, 0.60)
    while at < END:
        nxt = at + timedelta(days=random.randint(90, 150))
        last = nxt >= END
        prices.append((mid, iso(at), None if last else iso(nxt),
                       round(base, 4), round(base * 3, 4), round(base * 0.1, 4)))
        if last:
            break
        at = nxt
        base *= random.uniform(0.8, 1.1)
cur.executemany("INSERT INTO ModelPrice VALUES (?,?,?,?,?,?)", prices)

templates = [(1, "why_this_explainer"), (2, "conversational_search")]
cur.executemany("INSERT INTO PromptTemplate VALUES (?,?)", templates)

versions, vid_counter = [], 0
for tid, tname in templates:
    at = START
    for v in range(1, 19):
        vid_counter += 1
        versions.append((vid_counter, tid, v, f"{tname} prompt body v{v}", iso(at)))
        at += timedelta(days=random.randint(3, 12))
        if at >= END:
            break
cur.executemany("INSERT INTO PromptTemplateVersion VALUES (?,?,?,?,?)", versions)
version_by_time = sorted((datetime.strptime(v[4], "%Y-%m-%dT%H:%M:%SZ"), v[0])
                         for v in versions)

judges = [(1, 1, 1), (2, 1, 2), (3, 2, 1)]
cur.executemany("INSERT INTO JudgeVersion VALUES (?,?,?)", judges)

# Agent sessions
sessions, turns, tool_calls, recs, scores, ratings = [], [], [], [], [], []
turn_id = call_id = rec_id = 0

for sid in range(1, N_AGENT_SESSIONS + 1):
    uid = random.randint(1, N_USERS)
    s_start = random_time()
    sessions.append((sid, uid, iso(s_start)))

    at = s_start
    for seq in range(1, random.choices([1, 2, 3, 4, 5, 6],
                                       weights=[30, 28, 20, 12, 7, 3])[0] + 1):
        turn_id += 1
        at += timedelta(seconds=random.randint(5, 120))

        errored_turn = random.random() < 0.04
        if errored_turn:
            turns.append((turn_id, sid, seq, None, None,
                          "find me something like that clip", None, None,
                          None, None, None, iso(at)))
        else:
            tv = next((v for t, v in reversed(version_by_time) if t <= at),
                      version_by_time[0][1])
            mid = random.choices([1, 2, 3], weights=[60, 30, 10])[0]
            inp = int(random.lognormvariate(6.2, 0.5))
            out = int(random.lognormvariate(5.0, 0.6))
            turns.append((turn_id, sid, seq, tv, mid,
                          "find me something like that clip",
                          "here are a few clips that match",
                          round(random.uniform(0.0, 1.2), 2),
                          inp, out, int(inp * random.uniform(0, 0.4)), iso(at)))

        # tool calls, some nested
        for cs in range(1, random.choices([0, 1, 2, 3], weights=[15, 45, 30, 10])[0] + 1):
            call_id += 1
            parent = None
            if cs > 1 and random.random() < 0.35:
                parent = call_id - 1
            errored = 1 if random.random() < 0.05 else 0
            tool = random.choice(TOOLS)
            args = {"search_videos": {"query": "cat that thinks it's a dog",
                                      "filters": {"max_duration_ms": 60000}},
                    "get_user_history": {"days": random.choice([7, 30, 90])},
                    "fetch_trending_audio": {"region": random.choice(["IN", "US", "SG"])}}[tool]
            tool_calls.append((call_id, turn_id, cs, parent, tool,
                               json.dumps(args),
                               None if errored else "ok",
                               int(random.lognormvariate(5.2, 0.8)), errored))

        # shelf of recommendations
        if not errored_turn and random.random() < 0.7:
            for pos in range(1, random.randint(3, 6) + 1):
                rec_id += 1
                recs.append((rec_id, turn_id, pos, random.randint(1, N_VIDEOS)))

        # most turns are never judged
        if random.random() < 0.20:
            jv = random.choices([1, 2, 3], weights=[70, 20, 10])[0]
            scores.append((turn_id, jv,
                           round(random.betavariate(5, 2) * 4 + 1, 2),
                           round(random.betavariate(5, 2) * 4 + 1, 2),
                           round(random.betavariate(9, 1) * 4 + 1, 2),
                           iso(at + timedelta(days=random.randint(1, 30)))))
            if random.random() < 0.10:
                other = random.choice([v for v in (1, 2, 3) if v != jv])
                scores.append((turn_id, other,
                               round(random.betavariate(4, 3) * 4 + 1, 2),
                               round(random.betavariate(4, 3) * 4 + 1, 2),
                               round(random.betavariate(9, 1) * 4 + 1, 2),
                               iso(at + timedelta(days=random.randint(31, 90)))))

        if random.random() < 0.03:
            r_at = at + timedelta(seconds=random.randint(5, 300))
            first = "up" if random.random() < 0.72 else "down"
            ratings.append((turn_id, iso(r_at), first))
            if random.random() < 0.12:
                flipped = "down" if first == "up" else "up"
                ratings.append((turn_id,
                                iso(r_at + timedelta(seconds=random.randint(60, 900))),
                                flipped))

cur.executemany("INSERT INTO AgentSession VALUES (?,?,?)", sessions)
cur.executemany("INSERT INTO Turn VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", turns)
cur.executemany("INSERT INTO ToolCall VALUES (?,?,?,?,?,?,?,?,?)", tool_calls)
cur.executemany("INSERT INTO Recommendation VALUES (?,?,?,?)", recs)
cur.executemany("INSERT INTO JudgeScore VALUES (?,?,?,?,?,?)", scores)
cur.executemany("INSERT INTO UserRating VALUES (?,?,?)", ratings)

# Telemetry
video_duration = {v[0]: v[3] for v in videos}
# a few clips are shown far more than the rest
video_weights = power_law(N_VIDEOS, alpha=1.3, cap=5000)

impressions, segments, signals, share_details = [], [], [], []
imp_id = signal_id = 0
shown_videos = random.choices(range(1, N_VIDEOS + 1), weights=video_weights,
                              k=N_IMPRESSIONS)
viewers = random.choices(range(1, N_USERS + 1), weights=follow_weights,
                         k=N_IMPRESSIONS)
model_versions = ["v12", "v13", "v14"]

for i in range(N_IMPRESSIONS):
    imp_id += 1
    vid = shown_videos[i]
    uid = viewers[i]
    shown = random_time()
    rec = random.randint(1, rec_id) if (rec_id and random.random() < 0.01) else None
    impressions.append((imp_id, vid, uid, rec, iso(shown),
                        random.randint(0, 40), random.choice(model_versions)))

    # most impressions never become views
    if random.random() > 0.28:
        continue

    dur = video_duration[vid]
    at = shown + timedelta(seconds=random.randint(0, 2))
    for _ in range(random.choices([1, 2, 3], weights=[78, 17, 5])[0]):
        # watch time is right-skewed
        frac = min(random.betavariate(1.4, 2.2) + random.random() * 0.15, 1.0)
        watched_ms = max(int(dur * frac), 300)
        start_off = 0 if random.random() < 0.8 else random.randint(0, dur // 2)
        end_off = min(start_off + watched_ms, dur)
        if end_off <= start_off:
            continue
        # wall clock is stored to the second, the playhead in milliseconds
        ended = at + timedelta(seconds=max(1, round((end_off - start_off) / 1000)))
        segments.append((imp_id, iso(at), iso(ended), start_off, end_off))
        at = ended + timedelta(seconds=random.randint(1, 20))
        if at >= END:
            break

    # most views produce no signal
    if random.random() < 0.09:
        signal_id += 1
        stype = random.choices(SIGNALS, weights=SIGNAL_WEIGHTS)[0]
        s_at = shown + timedelta(seconds=random.randint(1, 120))
        signals.append((signal_id, uid, vid, stype, iso(s_at)))

        if stype == "share":
            share_details.append((signal_id,
                                  random.choices(["whatsapp", "instagram", "copied_link"],
                                                 weights=[55, 30, 15])[0]))
        if stype == "like" and random.random() < 0.12:
            signal_id += 1
            signals.append((signal_id, uid, vid, "like_retracted",
                            iso(s_at + timedelta(seconds=random.randint(3, 300)))))

cur.executemany("INSERT INTO Impression VALUES (?,?,?,?,?,?,?)", impressions)
cur.executemany("INSERT INTO ViewSegment VALUES (?,?,?,?,?)", segments)
cur.executemany("INSERT INTO Signal VALUES (?,?,?,?,?)", signals)
cur.executemany("INSERT INTO ShareDetail VALUES (?,?)", share_details)

con.commit()

print(f"seed {SEED}, scale {SCALE}")
for t in ["AppUser", "Creator", "Video", "AudioTrack", "Hashtag", "VideoHashtag",
          "ModerationDecision", "Follow", "Block", "Mute", "AgentSession", "Turn",
          "ToolCall", "Recommendation", "JudgeScore", "UserRating",
          "Impression", "ViewSegment", "Signal", "ShareDetail"]:
    n = cur.execute(f"SELECT count(*) FROM {t}").fetchone()[0]
    print(f"  {t:<20} {n:>8,}")

con.close()
