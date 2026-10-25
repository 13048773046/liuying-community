# -*- coding: utf-8 -*-
"""流萤社区 · 信息流 / 排行榜 / 搜索 / 热词 / 联想 / Banner。

feed：tab=all（默认时间序）| follow（关注流，复用音乐 follows）| recommend（热度序）。
热度分 = like×2 + comment×3 + share×4 + 浏览系数，时间衰减（半衰期 48h）。
"""
import os
import re
import json
import time
import uuid
import urllib.parse
import math

from common import (db, resolve_token, decorate_post, is_blocked, blocked_by, row_dict,
                    rate_limit, client_ip)

HALF_LIFE = 48 * 3600

# 推荐流候选窗口：避免全表扫描。半衰期 48h，7 天前帖子热度已衰减至 1/8，
# 基本不可能进入推荐排序前列；500 条上限对当前内容量充分覆盖。
RECOMMEND_WINDOW = 7 * 24 * 3600
RECOMMEND_MAX_CANDIDATES = 500


def _uid(c, handler):
    return resolve_token(c, handler.headers.get("Authorization", ""))


def _heat(d, views):
    """热度分：like*2 + comment*3 + share*4 + 浏览*0.5，时间衰减。"""
    score = (d.get("like_count", 0) * 2 + d.get("comment_count", 0) * 3 +
             d.get("share_count", 0) * 4 + (views or 0) * 0.5)
    age = max(time.time() - (d.get("created") or time.time()), 60)
    return score / math.pow(2, age / HALF_LIFE)


def _visible_sql():
    """信息流只展示：status=1 AND audit_status=1 AND taken_down=0。"""
    return "status=1 AND audit_status=1 AND taken_down=0"


def _handle_feed(self, c, u, api, method):
    if api != "/feed":
        return False
    query = urllib.parse.parse_qs(u.query)
    page = max(1, int((query.get("page") or ["1"])[0] or 1))
    size = min(50, max(1, int((query.get("size") or ["20"])[0] or 20)))
    board_id = (query.get("board_id") or [""])[0].strip()
    topic = (query.get("topic") or [""])[0].strip()
    ptype = (query.get("type") or [""])[0].strip()
    tab = (query.get("tab") or ["all"])[0].strip()
    if tab not in ("all", "follow", "recommend"):
        tab = "all"
    uid = _uid(c, self)
    where = [_visible_sql()]
    args = []
    if board_id:
        # 含子分类：该版块及其所有后代
        board_ids = [board_id]
        changed = True
        while changed:
            changed = False
            for row in c.execute("SELECT id FROM community_boards WHERE parent_id=? AND active=1",
                                 (board_id,)):
                if row[0] not in board_ids:
                    board_ids.append(row[0])
                    changed = True
        ph = ",".join("?" for _ in board_ids)
        where.append("board_id IN (%s)" % ph)
        args += board_ids
    if topic:
        where.append("topic LIKE ?")
        args.append("%" + topic + "%")
    if ptype:
        where.append("type=?")
        args.append(ptype)
    # 拉黑过滤：我不看被我拉黑的人
    if uid:
        blocked = [r[0] for r in c.execute(
            "SELECT blocked_id FROM community_blocks WHERE user_id=?", (uid,))]
        if blocked:
            ph = ",".join("?" for _ in blocked)
            where.append("user_id NOT IN (%s)" % ph)
            args += blocked
    order = "sticky DESC, created DESC"
    if tab == "follow":
        if not uid:
            order = "sticky DESC, created DESC"
        else:
            fids = [r[0] for r in c.execute(
                "SELECT following_id FROM follows WHERE follower_id=?", (uid,))]
            if fids:
                ph = ",".join("?" for _ in fids)
                where.append("user_id IN (%s)" % ph)
                args += fids
            else:
                where.append("1=0")
    elif tab == "recommend":
        # 候选窗口化（避免全表扫描）：created 近 RECOMMEND_WINDOW 且按时间倒序
        # 取最多 RECOMMEND_MAX_CANDIDATES 条，再按热度排序分页。
        w2 = list(where) + ["created >= ?"]
        a2 = args + [time.time() - RECOMMEND_WINDOW]
        rows0 = c.execute(
            "SELECT * FROM community_posts WHERE %s ORDER BY created DESC LIMIT ?"
            % " AND ".join(w2), a2 + [RECOMMEND_MAX_CANDIDATES]).fetchall()
        rows0 = [r for r in rows0 if not blocked_by(c, uid, row_dict(r)["user_id"])]
        rows0.sort(key=lambda r: _heat(row_dict(r), 0), reverse=True)
        total = len(rows0)
        sliced = rows0[(page - 1) * size: page * size]
        c.commit()
        self._ok({"list": [decorate_post(c, r, uid) for r in sliced],
                  "page": page, "size": size, "hasMore": page * size < total})
        return True
    sql = "SELECT * FROM community_posts WHERE %s ORDER BY %s LIMIT ? OFFSET ?" % (
        " AND ".join(where), order)
    args += [size, (page - 1) * size]
    rows = c.execute(sql, args).fetchall()
    c.commit()
    self._ok({"list": [decorate_post(c, r, uid) for r in rows],
              "page": page, "size": size, "hasMore": len(rows) == size})
    return True


def _handle_rankings(self, c, u, api, method):
    if api != "/rankings":
        return False
    query = urllib.parse.parse_qs(u.query)
    rtype = (query.get("type") or ["post"])[0].strip()
    uid = _uid(c, self)
    limit = min(100, max(1, int((query.get("limit") or ["20"])[0] or 20)))
    if rtype == "topic":
        rows = c.execute(
            "SELECT name, post_count FROM community_topics ORDER BY post_count DESC LIMIT ?",
            (limit,)).fetchall()
        c.commit()
        self._ok({"list": [{"name": r[0], "count": r[1]} for r in rows]})
        return True
    if rtype == "user":
        rows = c.execute(
            "SELECT e.user_id, e.exp, e.level, u.name, u.avatar FROM community_exp e"
            " JOIN users u ON u.id=e.user_id ORDER BY e.exp DESC LIMIT ?", (limit,)).fetchall()
        c.commit()
        self._ok({"list": [{"user": {"id": r[0], "name": r[3] or "", "avatar": r[4] or ""},
                            "exp": r[1], "level": r[2]} for r in rows]})
        return True
    # 默认 post 热榜
    rows = c.execute(
        "SELECT * FROM community_posts WHERE %s ORDER BY like_count*2+comment_count*3+share_count*4 DESC"
        " LIMIT ?" % _visible_sql(), (limit,)).fetchall()
    rows = [r for r in rows if not blocked_by(c, uid, row_dict(r)["user_id"])]
    c.commit()
    self._ok({"list": [decorate_post(c, r, uid) for r in rows]})
    return True


def _handle_search(self, c, u, api, method):
    if api != "/search":
        return False
    query = urllib.parse.parse_qs(u.query)
    q = (query.get("q") or [""])[0].strip()
    stype = (query.get("type") or [""])[0].strip()
    page = max(1, int((query.get("page") or ["1"])[0] or 1))
    size = min(50, max(1, int((query.get("size") or ["20"])[0] or 20)))
    uid = _uid(c, self)
    if not q:
        self._err(400, "缺少搜索词")
        return True
    if not rate_limit(self, "search"):
        self._err(429, "搜索过于频繁")
        return True
    # 搜索日志（登录用户）
    if uid:
        c.execute("INSERT INTO community_search_logs(id,user_id,q,created) VALUES(?,?,?,?)",
                  (uuid.uuid4().hex, uid, q[:50], time.time()))
    like = "%" + q + "%"
    result = {"posts": [], "videos": [], "users": [], "topics": []}
    if stype in ("", "post", "video"):
        st = "video" if stype == "video" else stype
        sql = "SELECT * FROM community_posts WHERE %s AND content LIKE ? ORDER BY created DESC LIMIT ? OFFSET ?"
        args = [like, size, (page - 1) * size]
        if st:
            sql = "SELECT * FROM community_posts WHERE %s AND type=? AND content LIKE ? ORDER BY created DESC LIMIT ? OFFSET ?"
            args = [st, like, size, (page - 1) * size]
        rows = c.execute(sql % _visible_sql(), args).fetchall()
        key = "videos" if stype == "video" else "posts"
        result[key] = [decorate_post(c, r, uid) for r in rows]
    if stype in ("", "user"):
        rows = c.execute(
            "SELECT id,name,avatar FROM users WHERE name LIKE ? OR account LIKE ? LIMIT ?",
            (like, like, size)).fetchall()
        result["users"] = [{"id": r[0], "name": r[1] or "", "avatar": r[2] or ""} for r in rows]
    if stype in ("", "topic"):
        rows = c.execute("SELECT name, post_count FROM community_topics WHERE name LIKE ? LIMIT ?",
                         (like, size)).fetchall()
        result["topics"] = [{"name": r[0], "count": r[1]} for r in rows]
    c.commit()
    self._ok(result)
    return True


def _handle_suggest(self, c, u, api, method):
    if api != "/search/suggest":
        return False
    query = urllib.parse.parse_qs(u.query)
    q = (query.get("q") or [""])[0].strip()
    if not q:
        self._ok({"list": []})
        return True
    like = q + "%"
    topics = [r[0] for r in c.execute(
        "SELECT name FROM community_topics WHERE name LIKE ? ORDER BY post_count DESC LIMIT 5",
        (like,)).fetchall()]
    users = [{"id": r[0], "name": r[1] or ""} for r in c.execute(
        "SELECT id,name FROM users WHERE name LIKE ? LIMIT 5", (like,)).fetchall()]
    c.commit()
    self._ok({"topics": topics, "users": users})
    return True


def _handle_hot(self, c, u, api, method):
    if api != "/search/hot":
        return False
    since = time.time() - 7 * 24 * 3600
    rows = c.execute(
        "SELECT q, COUNT(*) cnt FROM community_search_logs WHERE created>? GROUP BY q"
        " ORDER BY cnt DESC LIMIT 20", (since,)).fetchall()
    c.commit()
    self._ok({"list": [{"q": r[0], "count": r[1]} for r in rows]})
    return True


def _handle_banners(self, c, u, api, method):
    if api != "/banners":
        return False
    now = time.time()
    rows = c.execute(
        "SELECT * FROM community_banners WHERE active=1 AND (start_at=0 OR start_at<=?)"
        " AND (end_at=0 OR end_at>=?) ORDER BY sort ASC LIMIT 10",
        (now, now)).fetchall()
    out = []
    for r in rows:
        d = row_dict(r)
        out.append({"id": d["id"], "image": d["image"],
                    "linkType": d["link_type"], "linkId": d["link_id"]})
    c.commit()
    self._ok({"list": out})
    return True


def dispatch(self, c, u, api, method):
    handlers = [_handle_feed, _handle_rankings, _handle_search,
                _handle_suggest, _handle_hot, _handle_banners]
    for h in handlers:
        if h(self, c, u, api, method):
            return True
    return False
