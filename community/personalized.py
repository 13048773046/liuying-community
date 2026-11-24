# -*- coding: utf-8 -*-
"""流萤社区 · 个性化推荐。

参考音乐项目 server/recommend.py 的「多路召回 → 画像加权 → 多样性重排」思路，
按社区内容形态落地：行为画像（板块/话题/作者）、相似用户协同、关注、热度、
新鲜、探索、时段场景七路召回；同作者/同板块限流做 MMR 式多样性；3 小时推送去重。
"""
import hashlib
import json
import math
import random
import time

from common import row_dict

VISIBLE = "status=1 AND audit_status=1 AND taken_down=0"
REC_CAND_LIMIT = 800
REC_POOL_LIMIT = 140
REC_PUSH_WINDOW = 3 * 3600
REC_WINDOW = 30 * 86400
REC_SEEN_DAYS = 7
REC_MAX_PER_AUTHOR = 3
REC_MAX_PER_BOARD = 5

_W = {
    "behavior_board": 2.8,
    "behavior_topic": 2.2,
    "behavior_author": 1.6,
    "collab": 1.4,
    "follow": 2.4,
    "hot": 1.0,
    "fresh": 1.1,
    "explore": 0.28,
    "scene": 0.9,
}
_EVENT_W = {
    "view": 1.0, "open": 1.5, "like": 4.0, "unlike": -1.0,
    "fav": 6.0, "unfav": -3.0, "later": 2.0, "unlater": -1.0,
    "comment": 5.0, "share": 5.0, "vote": 2.5,
    "not_interested": -8.0,
}
_STRONG = {"like", "fav", "comment", "share", "vote"}


def _decay(age_days):
    if age_days <= 1.0 / 24:
        return 1.5
    if age_days <= 1.0:
        return 1.25
    if age_days <= 7.0:
        return 1.0
    if age_days <= 30.0:
        return 0.7
    return 0.4


def _topics(raw):
    if isinstance(raw, list):
        return [str(x) for x in raw if str(x).strip()][:10]
    try:
        v = json.loads(raw or "[]")
        return [str(x) for x in v if str(x).strip()][:10] if isinstance(v, list) else []
    except Exception:
        return []


def _post_dict(row):
    d = row_dict(row)
    d["_topics"] = _topics(d.get("topic"))
    d["_row"] = row
    return d


def _profile(c, uid, now):
    """从行为事件提取画像：板块/话题/作者权重、已看集合、强互动集合。"""
    out = {"board": {}, "topic": {}, "author": {}, "seen": set(), "strong": set(),
           "not_interested": set(), "events": 0}
    if not uid:
        return out
    evs = c.execute(
        "SELECT post_id,event,value,meta,created FROM community_behavior_events"
        " WHERE user_id=? AND created>=? ORDER BY created DESC LIMIT 800",
        (uid, now - 60 * 86400)).fetchall()
    out["events"] = len(evs)
    ids = list({r[0] for r in evs if r[0]})
    info = {}
    for i in range(0, len(ids), 200):
        chunk = ids[i:i + 200]
        ph = ",".join("?" for _ in chunk)
        for r in c.execute("SELECT id,board_id,topic,user_id,type FROM community_posts WHERE id IN (%s)" % ph,
                           chunk).fetchall():
            info[r[0]] = {"board": r[1] or "", "topics": _topics(r[2]),
                          "author": r[3] or "", "type": r[4] or ""}
    for pid, event, value, meta, created in evs:
        age = max(now - float(created or now), 0) / 86400.0
        w = _EVENT_W.get(event, 0) * _decay(age)
        item = info.get(pid, {})
        if not item and meta:
            try:
                m = json.loads(meta)
                item = {"board": m.get("boardId") or "",
                        "topics": _topics(m.get("topics") or []),
                        "author": m.get("authorId") or "", "type": m.get("type") or ""}
            except Exception:
                item = {}
        if w > 0:
            if item.get("board"):
                out["board"][item["board"]] = out["board"].get(item["board"], 0.0) + w
            for t in item.get("topics") or []:
                out["topic"][t] = out["topic"].get(t, 0.0) + w * 0.9
            if item.get("author"):
                out["author"][item["author"]] = out["author"].get(item["author"], 0.0) + w
        if event in _STRONG or (event == "view" and age <= REC_SEEN_DAYS):
            out["seen"].add(pid)
        if event in _STRONG:
            out["strong"].add(pid)
        if event == "not_interested":
            out["seen"].add(pid)
            out["not_interested"].add(pid)
    return out


def _board_ids(c, board_id):
    if not board_id:
        return []
    ids = [board_id]
    changed = True
    while changed:
        changed = False
        for row in c.execute("SELECT id FROM community_boards WHERE parent_id=? AND active=1",
                             (board_id,)):
            if row[0] not in ids:
                ids.append(row[0])
                changed = True
    return ids


def _blocks(c, uid):
    if not uid:
        return set()
    rows = c.execute(
        "SELECT user_id,blocked_id FROM community_blocks WHERE user_id=? OR blocked_id=?",
        (uid, uid)).fetchall()
    return {r[0] for r in rows} | {r[1] for r in rows}


def _view_counts(c, now):
    rows = c.execute(
        "SELECT post_id,COUNT(*) FROM community_behavior_events"
        " WHERE event='view' AND created>=? GROUP BY post_id", (now - 14 * 86400,)).fetchall()
    return {r[0]: int(r[1]) for r in rows}


def _heat(d, views):
    score = (d.get("like_count", 0) * 2 + d.get("comment_count", 0) * 3 +
             d.get("share_count", 0) * 4 + (views or 0) * 0.5)
    age = max(time.time() - (d.get("created") or time.time()), 60)
    return score / math.pow(2, age / (72 * 3600))


def _scene(now):
    """时段场景：夜间治愈 / 周末灵感；返回 (标签, 关键词)。"""
    lt = time.localtime(now)
    hour, weekday = lt.tm_hour, lt.tm_wday
    if hour >= 22 or hour < 6:
        return "夜间治愈", ("深夜", "晚安", "情感", "失眠", "夜", "树洞", "独处")
    if weekday >= 5:
        return "周末灵感", ("周末", "探店", "露营", "旅行", "咖啡", "市集", "散步")
    if 11 <= hour < 14:
        return "午间轻松", ("美食", "一人食", "咖啡", "摸鱼", "日常")
    return "今日精选", ("日常", "生活", "分享", "城市")


def _noise(uid, bucket, pid, amp):
    h = hashlib.sha1(("%s|%s|%s" % (uid or "anon", bucket, pid)).encode("utf-8")).hexdigest()
    return (int(h[:10], 16) / float(0xFFFFFFFFFF)) * amp


def _reason(item, prof, follow_ids, board_names):
    src = item["sources"]
    p = item["post"]
    if "follow" in src and p.get("user_id") in follow_ids:
        return "你关注的人刚刚更新"
    if "behavior_board" in src:
        bs = [(prof["board"].get(b, 0), b) for b in [p.get("board_id")] if b]
        if bs:
            return "因为你常看「%s」" % board_names.get(bs[0][1], "这个板块")
    if "behavior_topic" in src:
        ts = [(prof["topic"].get(t, 0), t) for t in p.get("_topics") or []]
        if ts:
            return "你关注的话题 #%s" % max(ts)[1]
    if "behavior_author" in src:
        return "你常和这位作者互动"
    if "collab" in src:
        return "和你口味相近的人也在看"
    if "scene" in src:
        return item.get("scene_label") or "应景推荐"
    if "hot" in src:
        return "社区热议"
    if "fresh" in src:
        return "新鲜发布"
    return "发现新内容"


def _rank(pool, uid, bucket, limit, noise_amp):
    """带作者/板块上限的多样性重排。"""
    ranked = []
    used_a, used_b = {}, {}
    while pool and len(ranked) < limit:
        best, best_score = None, -1e18
        for it in pool:
            p = it["post"]
            a, b = p.get("user_id") or "", p.get("board_id") or ""
            if a and used_a.get(a, 0) >= REC_MAX_PER_AUTHOR:
                continue
            if b and used_b.get(b, 0) >= REC_MAX_PER_BOARD:
                continue
            s = it["score"] - used_a.get(a, 0) * 0.20 - used_b.get(b, 0) * 0.10
            s += _noise(uid, bucket, p.get("id"), noise_amp)
            if s > best_score:
                best, best_score = it, s
        if best is None:
            break
        pool.remove(best)
        ranked.append(best)
        p = best["post"]
        a, b = p.get("user_id") or "", p.get("board_id") or ""
        if a:
            used_a[a] = used_a.get(a, 0) + 1
        if b:
            used_b[b] = used_b.get(b, 0) + 1
    # 上限导致候选没用完时，忽略上限补齐（小社区内容量优先）
    if len(ranked) < limit:
        rest = sorted(pool, key=lambda x: x["score"], reverse=True)
        ranked.extend(rest[:limit - len(ranked)])
    return ranked


def build_personalized(c, uid, page=1, size=20, board_id="", topic="", ptype="",
                       exclude=None, fresh=False, with_push=True):
    """返回 (rows, has_more, pushed_ids)；rows 为 [(sqlite Row, reason)]。"""
    now = time.time()
    page = max(1, int(page or 1))
    size = max(1, min(50, int(size or 20)))
    profile = _profile(c, uid, now)
    board_names = {r[0]: r[1] for r in c.execute("SELECT id,name FROM community_boards").fetchall()}
    blocked = _blocks(c, uid)

    exclude_ids = set(exclude or []) | set(profile["seen"])
    pushed = set()
    if with_push and uid and page == 1 and not fresh:
        c.execute("DELETE FROM community_recommend_push WHERE pushed_at<=?", (now - REC_PUSH_WINDOW,))
        pushed = {r[0] for r in c.execute(
            "SELECT post_id FROM community_recommend_push WHERE uid=? AND pushed_at>?",
            (uid, now - REC_PUSH_WINDOW)).fetchall()}

    # ---------- 候选池 ----------
    where = [VISIBLE, "created>=?"]
    args = [now - REC_WINDOW]
    if board_id:
        bids = _board_ids(c, board_id)
        where.append("board_id IN (%s)" % ",".join("?" for _ in bids))
        args += bids
    if topic:
        where.append("topic LIKE ?")
        args.append("%" + topic + "%")
    if ptype:
        where.append("type=?")
        args.append(ptype)
    rows = c.execute(
        "SELECT * FROM community_posts WHERE %s ORDER BY created DESC LIMIT ?" % " AND ".join(where),
        args + [REC_CAND_LIMIT]).fetchall()
    candidates = [_post_dict(r) for r in rows]
    candidates = [p for p in candidates if p.get("user_id") != uid and p.get("user_id") not in blocked]
    views = _view_counts(c, now)

    # ---------- 行为画像 ----------
    mb = max(profile["board"].values(), default=0.0)
    mt = max(profile["topic"].values(), default=0.0)
    ma = max(profile["author"].values(), default=0.0)
    cand = {}
    for p in candidates:
        pid = p["id"]
        if pid in exclude_ids or pid in pushed:
            continue
        aff = 0.0
        src = set()
        if mb and p.get("board_id") in profile["board"]:
            aff += _W["behavior_board"] * profile["board"][p["board_id"]] / mb
            src.add("behavior_board")
        if mt:
            hits = [profile["topic"][t] for t in p["_topics"] if t in profile["topic"]]
            if hits:
                aff += _W["behavior_topic"] * max(hits) / mt
                src.add("behavior_topic")
        if ma and p.get("user_id") in profile["author"]:
            aff += _W["behavior_author"] * profile["author"][p["user_id"]] / ma
            src.add("behavior_author")
        item = {"post": p, "score": aff, "sources": src}
        cand[pid] = item

    def add(pid, score, source):
        it = cand.get(pid)
        if it is None:
            return
        it["score"] += score
        it["sources"].add(source)

    # ---------- 协同：相似用户喜欢的内容 ----------
    strong = list(profile["strong"])[:120]
    peer_ids = []
    if uid and strong:
        ph = ",".join("?" for _ in strong)
        peers = c.execute(
            "SELECT user_id,COUNT(*) n FROM community_behavior_events"
            " WHERE post_id IN (%s) AND user_id!=? AND event IN ('like','fav','comment','share')"
            " AND created>=? GROUP BY user_id ORDER BY n DESC LIMIT 24" % ph,
            strong + [uid, now - 60 * 86400]).fetchall()
        peer_ids = [r[0] for r in peers]
    if peer_ids:
        ph = ",".join("?" for _ in peer_ids)
        liked = c.execute(
            "SELECT post_id,COUNT(*) n FROM community_behavior_events"
            " WHERE user_id IN (%s) AND event IN ('like','fav','comment','share')"
            " AND created>=? GROUP BY post_id ORDER BY n DESC LIMIT 160" % ph,
            peer_ids + [now - 30 * 86400]).fetchall()
        mx = max((r[1] for r in liked), default=1)
        for pid, n in liked:
            add(pid, _W["collab"] * (n / float(mx)), "collab")

    # ---------- 关注路 ----------
    follow_ids = set()
    if uid:
        follow_ids = {r[0] for r in c.execute(
            "SELECT following_id FROM follows WHERE follower_id=?", (uid,)).fetchall()}
        for p in candidates:
            if p.get("user_id") in follow_ids and p["id"] not in exclude_ids and p["id"] not in pushed:
                add(p["id"], _W["follow"], "follow")

    # ---------- 热度 / 新鲜 / 探索 / 场景 ----------
    heats = [(p["id"], _heat(p, views.get(p["id"], 0))) for p in candidates]
    mh = max((h for _, h in heats), default=0.0)
    for pid, h in heats:
        if mh:
            add(pid, _W["hot"] * (h / mh), "hot")
    for p in candidates:
        age = max(now - float(p.get("created") or now), 0) / 3600.0
        if age <= 72:
            add(p["id"], _W["fresh"] * max(0.0, 1.0 - age / 72.0), "fresh")

    scene_label, scene_kws = _scene(now)
    for p in candidates:
        if p["id"] not in cand:
            continue
        text = (p.get("content") or "") + " " + board_names.get(p.get("board_id"), "")
        if any(k in text or any(k in t for t in p["_topics"]) for k in scene_kws):
            add(p["id"], _W["scene"], "scene")
            cand[p["id"]]["scene_label"] = scene_label

    # 探索：不在画像/热度候选里的内容也保留曝光机会
    rnd = random.Random(hash("%s|%s|%s" % (uid or "anon", now // 1800, "explore")))
    rest = [p for p in candidates
            if p["id"] not in cand and p["id"] not in exclude_ids and p["id"] not in pushed]
    rnd.shuffle(rest)
    for p in rest[:max(12, size * 2)]:
        cand[p["id"]] = {"post": p, "score": _W["explore"] + rnd.random() * 0.12,
                         "sources": {"explore"}}

    # ---------- 重排 ----------
    pool = list(cand.values())
    noise = 0.38 if fresh else 0.12
    ranked = _rank(pool, uid or "anon", (uid or "anon", now // 1800), max(REC_POOL_LIMIT, page * size + 20), noise)
    if len(ranked) < page * size and pushed:
        # 3 小时去重把内容掏空时，放开历史重排（宁可重复也不空屏）
        allow = [p for p in candidates if p["id"] not in exclude_ids]
        tmp = {}
        for p in allow:
            tmp[p["id"]] = {"post": p, "score": 1.0, "sources": {"explore"}}
        ranked = _rank(list(tmp.values()), uid or "anon", (uid or "anon", now // 1800),
                       max(REC_POOL_LIMIT, page * size + 20), noise)
    start = (page - 1) * size
    sliced = ranked[start:start + size]
    out = []
    for it in sliced:
        p = it["post"]
        out.append((p["_row"], _reason(it, profile, follow_ids, board_names)))
    has_more = page * size < len(ranked)
    return out, has_more, [p["id"] for p, _ in out]


def remember_pushed(c, uid, post_ids, now=None):
    """记录本批推荐，3 小时内不再推给同一用户（覆盖时间戳）。"""
    if not uid or not post_ids:
        return
    now = now or time.time()
    c.execute("DELETE FROM community_recommend_push WHERE pushed_at<=?", (now - REC_PUSH_WINDOW,))
    c.executemany(
        "INSERT OR REPLACE INTO community_recommend_push(uid,post_id,pushed_at) VALUES(?,?,?)",
        [(uid, pid, now) for pid in post_ids[:60]])
