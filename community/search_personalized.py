# -*- coding: utf-8 -*-
"""搜索 / 用户主页的结果级个性化。

搜索不能牺牲相关性：先保证 LIKE 命中，再用行为画像做同分段的语义加权，
并在结果上给出可解释 reason。未登录或没有画像时回退到相关度 + 热度。
"""
import time

from common import row_dict
from personalized import _profile, _topics


def _text(value):
    return (value or "").strip()


def _profile_ready(profile):
    return bool(profile.get("events"))


def rank_posts(c, uid, rows, q, limit):
    """返回 [(sqlite Row, reason)]。rows 必须已经通过搜索相关性过滤。"""
    if not rows:
        return []
    now = time.time()
    prof = _profile(c, uid, now)
    board_names = {r[0]: r[1] for r in c.execute(
        "SELECT id,name FROM community_boards").fetchall()}
    mb = max(prof["board"].values(), default=0.0)
    mt = max(prof["topic"].values(), default=0.0)
    ma = max(prof["author"].values(), default=0.0)
    ql = q.lower()

    items = []
    for row in rows:
        d = row_dict(row)
        content = _text(d.get("content"))
        low = content.lower()
        # 相关性是搜索的底座；个性化只在其上做小幅加权。
        relevance = 2.4 if low.startswith(ql) else 1.6 if ql in low else 0.8
        age = max(now - float(d.get("created") or now), 60) / 86400.0
        recency = max(0.0, 0.35 * (1.0 - min(age, 14.0) / 14.0))
        heat = (d.get("like_count", 0) * 2 + d.get("comment_count", 0) * 3 +
                d.get("share_count", 0) * 4)
        hot = min(1.0, heat / 80.0)
        affinity = 0.0
        reason = ""
        if mb and d.get("board_id") in prof["board"]:
            affinity += 1.8 * prof["board"][d["board_id"]] / mb
            reason = "因为你常看「%s」" % board_names.get(d.get("board_id"), "这个板块")
        if mt:
            hits = [(prof["topic"].get(t, 0.0), t) for t in _topics(d.get("topic"))
                    if t in prof["topic"]]
            if hits:
                w, topic = max(hits)
                affinity += 1.5 * w / mt
                reason = "你关注的话题 #%s" % topic
        if ma and d.get("user_id") in prof["author"]:
            affinity += 1.1 * prof["author"][d["user_id"]] / ma
            if not reason:
                reason = "你常和这位作者互动"
        score = relevance + affinity + hot * 0.8 + recency
        if not reason:
            reason = "搜索热门" if hot >= 0.35 else ("和你的兴趣相关"
                    if _profile_ready(prof) else "相关结果")
        items.append({"row": row, "score": score, "reason": reason})

    items.sort(key=lambda x: x["score"], reverse=True)
    out = []
    author_n = {}
    for item in items:
        d = row_dict(item["row"])
        author = d.get("user_id") or ""
        if author and author_n.get(author, 0) >= 3:
            continue
        if author:
            author_n[author] = author_n.get(author, 0) + 1
        out.append((item["row"], item["reason"]))
        if len(out) >= limit:
            break
    # 去重后不足时按原始分数补回，搜索宁可多给结果也不空屏。
    if len(out) < limit:
        seen = {row_dict(r).get("id") for r, _ in out}
        for item in items:
            pid = row_dict(item["row"]).get("id")
            if pid in seen:
                continue
            out.append((item["row"], item["reason"]))
            if len(out) >= limit:
                break
    return out


def rank_users(c, uid, rows, q, limit):
    if not rows:
        return []
    prof = _profile(c, uid, time.time())
    ma = max(prof["author"].values(), default=0.0)
    ql = q.lower()
    ids = [r[0] for r in rows]
    followers = {}
    following = set()
    if ids:
        ph = ",".join("?" for _ in ids)
        followers = {r[0]: r[1] for r in c.execute(
            "SELECT following_id,COUNT(*) FROM follows WHERE following_id IN (%s)"
            " GROUP BY following_id" % ph, ids).fetchall()}
        if uid:
            following = {r[0] for r in c.execute(
                "SELECT following_id FROM follows WHERE follower_id=? AND following_id IN (%s)"
                % ph, [uid] + ids).fetchall()}
    items = []
    for r in rows:
        name = r[1] or ""
        low = name.lower()
        exact = 3.0 if low == ql else 2.0 if low.startswith(ql) else 1.0
        affinity = (1.6 * prof["author"].get(r[0], 0.0) / ma) if ma else 0.0
        score = exact + affinity + min(1.0, followers.get(r[0], 0) / 100.0)
        reason = "相关用户"
        if uid and r[0] in following:
            reason = "你关注的人"
        elif affinity:
            reason = "你常和 TA 互动"
        items.append({"row": r, "score": score, "reason": reason,
                      "followers": followers.get(r[0], 0)})
    items.sort(key=lambda x: x["score"], reverse=True)
    return [(x["row"], x["reason"], x["followers"]) for x in items[:limit]]


def rank_topics(c, uid, rows, q, limit):
    if not rows:
        return []
    prof = _profile(c, uid, time.time())
    mt = max(prof["topic"].values(), default=0.0)
    ql = q.lower()
    items = []
    for name, count in rows:
        nm = name or ""
        low = nm.lower()
        exact = 2.8 if low == ql else 1.8 if low.startswith(ql) else 0.8
        affinity = (1.8 * prof["topic"].get(nm, 0.0) / mt) if mt else 0.0
        score = exact + affinity + min(1.0, (count or 0) / 30.0)
        reason = "你关注的话题" if affinity else ("热门话题" if (count or 0) >= 5 else "相关话题")
        items.append({"name": nm, "count": count, "reason": reason,
                      "score": score})
    items.sort(key=lambda x: x["score"], reverse=True)
    return items[:limit]

def rank_profile_posts(c, uid, target, rows, limit):
    """用户主页作品：在查看者兴趣/关注关系上重排，但保持目标用户自己的作品集合。"""
    if not rows:
        return []
    now = time.time()
    prof = _profile(c, uid, now)
    board_names = {r[0]: r[1] for r in c.execute(
        "SELECT id,name FROM community_boards").fetchall()}
    mb = max(prof["board"].values(), default=0.0)
    mt = max(prof["topic"].values(), default=0.0)
    following = bool(uid and target and c.execute(
        "SELECT 1 FROM follows WHERE follower_id=? AND following_id=?",
        (uid, target)).fetchone())
    items = []
    for row in rows:
        d = row_dict(row)
        age = max(now - float(d.get("created") or now), 60) / 86400.0
        recency = max(0.0, 0.8 * (1.0 - min(age, 30.0) / 30.0))
        heat = (d.get("like_count", 0) * 2 + d.get("comment_count", 0) * 3 +
                d.get("share_count", 0) * 4)
        hot = min(1.0, heat / 80.0)
        affinity = 0.0
        reason = ""
        if mb and d.get("board_id") in prof["board"]:
            affinity += 1.8 * prof["board"][d["board_id"]] / mb
            reason = "因为你常看「%s」" % board_names.get(d.get("board_id"), "这个板块")
        if mt:
            hits = [(prof["topic"].get(t, 0.0), t) for t in _topics(d.get("topic"))
                    if t in prof["topic"]]
            if hits:
                w, topic = max(hits)
                affinity += 1.5 * w / mt
                reason = "你关注的话题 #%s" % topic
        score = affinity + hot * 0.55 + recency
        if not reason:
            reason = ("你关注的人的作品" if following
                      else "TA 的热门作品" if hot >= 0.45 else "TA 的最新作品")
        items.append({"row": row, "score": score, "reason": reason})
    items.sort(key=lambda x: x["score"], reverse=True)
    return [(x["row"], x["reason"]) for x in items[:limit]]
