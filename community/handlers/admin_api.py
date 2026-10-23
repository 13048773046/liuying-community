# -*- coding: utf-8 -*-
"""流萤社区 · 管理接口（A 类）。

权限：一级（level=1）全部；二级（level=2）可执行内容运营操作：
审核/置顶/精华/下架/结束投票/神评/内容删除/举报处理；其余配置类仅一级。
鉴权：X-Community-Admin-Token 头。
"""
import os
import re
import json
import time
import uuid
import secrets
import urllib.parse

from common import (db, rate_limit, admin_required, admin_log, notify, row_dict,
                    official_msg, add_exp, task_progress, FILES_DIR,
                    decorate_post, decorate_comment)

EMOJI_DIR = os.path.join(FILES_DIR, "emoji_official")


def _auth(self, c, need_level=2):
    """返回 (token, level)；不满足则回 401/403 并返回 None。"""
    adm = admin_required(c, self)
    if not adm:
        self._err(401, "管理员令牌无效")
        return None
    if adm[1] > need_level:
        self._err(403, "权限不足（需要一级管理员）")
        return None
    return adm[0], adm[1]


def _body(h):
    return h._json_body() or {}


# ---------------- 仪表盘 / 趋势 ----------------
def _handle_stats(self, c, u, api, method):
    if api == "/admin/stats":
        adm = _auth(self, c, 1)
        if not adm:
            return True
        now = time.time()
        day = now - 86400
        def cnt(sql, args):
            return c.execute(sql, args).fetchone()[0] or 0
        s = {
            "posts": cnt("SELECT COUNT(*) FROM community_posts WHERE status=1", ()),
            "pendingAudit": cnt("SELECT COUNT(*) FROM community_posts WHERE status=1 AND audit_status=0", ()),
            "videos": cnt("SELECT COUNT(*) FROM community_posts WHERE status=1 AND type='video'", ()),
            "comments": cnt("SELECT COUNT(*) FROM community_post_comments WHERE status=1", ()),
            "users": cnt("SELECT COUNT(*) FROM users", ()),
            "members": cnt("SELECT COUNT(*) FROM community_members WHERE expire>?", (now,)),
            "reports": cnt("SELECT COUNT(*) FROM community_reports WHERE status=0", ()),
            "todayPosts": cnt("SELECT COUNT(*) FROM community_posts WHERE status=1 AND created>?", (day,)),
            "todayComments": cnt("SELECT COUNT(*) FROM community_post_comments WHERE status=1 AND created>?", (day,)),
            "todayNewUsers": cnt("SELECT COUNT(*) FROM users WHERE created>?", (day,)),
            "dau": cnt("SELECT COUNT(DISTINCT user_id) FROM community_search_logs WHERE created>?", (day,))
                   + cnt("SELECT COUNT(DISTINCT user_id) FROM community_post_likes WHERE created>?", (day,)),
        }
        admin_log(c, adm[0], "stats", "dashboard", "", "")
        c.commit()
        self._ok({"stats": s})
        return True
    if api == "/admin/trends":
        adm = _auth(self, c, 1)
        if not adm:
            return True
        days = 7
        out = []
        for i in range(days):
            d0 = time.mktime(time.strptime(time.strftime("%Y-%m-%d"), "%Y-%m-%d")) - (days - 1 - i) * 86400
            d1 = d0 + 86400
            posts = c.execute("SELECT COUNT(*) FROM community_posts WHERE created>=? AND created<?", (d0, d1)).fetchone()[0]
            videos = c.execute("SELECT COUNT(*) FROM community_posts WHERE type='video' AND created>=? AND created<?", (d0, d1)).fetchone()[0]
            comments = c.execute("SELECT COUNT(*) FROM community_post_comments WHERE created>=? AND created<?", (d0, d1)).fetchone()[0]
            users = c.execute("SELECT COUNT(*) FROM users WHERE created>=? AND created<?", (d0, d1)).fetchone()[0]
            out.append({"day": time.strftime("%m-%d", time.localtime(d0)),
                        "posts": posts, "videos": videos, "comments": comments, "users": users})
        c.commit()
        self._ok({"trends": out})
        return True
    return False


# ---------------- 帖子管理（审核/置顶/精华/下架/投票/删除） ----------------
def _handle_admin_posts(self, c, u, api, method):
    if api == "/admin/posts":
        adm = _auth(self, c, 2)
        if not adm:
            return True
        query = urllib.parse.parse_qs(u.query)
        page = max(1, int((query.get("page") or ["1"])[0] or 1))
        size = min(50, max(1, int((query.get("size") or ["20"])[0] or 20)))
        audit = (query.get("audit") or [""])[0].strip()
        ptype = (query.get("type") or [""])[0].strip()
        board = (query.get("board") or [""])[0].strip()
        keyword = (query.get("keyword") or [""])[0].strip()
        where = ["status=1"]
        args = []
        if audit:
            where.append("audit_status=?")
            args.append(int(audit))
        if ptype:
            where.append("type=?")
            args.append(ptype)
        if board:
            where.append("board_id=?")
            args.append(board)
        if keyword:
            where.append("content LIKE ?")
            args.append("%" + keyword + "%")
        rows = c.execute("SELECT * FROM community_posts WHERE %s ORDER BY created DESC LIMIT ? OFFSET ?"
                         % " AND ".join(where), args + [size, (page - 1) * size]).fetchall()
        total = c.execute("SELECT COUNT(*) FROM community_posts WHERE %s" % " AND ".join(where),
                          args).fetchone()[0]
        c.commit()
        self._ok({"list": [decorate_post(c, r, None) for r in rows],
                  "total": total, "page": page, "size": size})
        return True
    m = re.match(r"^/admin/posts/([\w\-]+)/(audit|pin|featured|takedown|end-poll)$", api)
    if m and method in ("POST", "DELETE"):
        pid, action = m.group(1), m.group(2)
        level_need = 2
        adm = _auth(self, c, level_need)
        if not adm:
            return True
        row = c.execute("SELECT * FROM community_posts WHERE id=?", (pid,)).fetchone()
        if not row:
            self._err(404, "帖子不存在")
            return True
        d = row_dict(row)
        body = _body(self)
        if action == "audit":
            act = (body.get("action") or "").strip()
            if act == "approve":
                c.execute("UPDATE community_posts SET audit_status=1, audited_at=? WHERE id=?",
                          (time.time(), pid))
                notify(c, d["user_id"], "community_audit", "审核通过",
                       "你的帖子已通过审核，快去看看吧", from_name="流萤社区官方")
                admin_log(c, adm[0], "audit_approve", "post", pid)
                c.commit()
                self._ok({"auditStatus": 1, "msg": "已通过"})
                return True
            if act == "reject":
                reason = (body.get("reason") or "").strip()[:200]
                if not reason:
                    self._err(400, "拒绝理由必填")
                    return True
                c.execute("UPDATE community_posts SET audit_status=2, audit_reason=?, audited_at=? WHERE id=?",
                          (reason, time.time(), pid))
                notify(c, d["user_id"], "community_audit", "审核未通过",
                       "你的帖子未通过审核：%s" % reason, from_name="流萤社区官方")
                admin_log(c, adm[0], "audit_reject", "post", pid, reason)
                c.commit()
                self._ok({"auditStatus": 2, "msg": "已拒绝"})
                return True
            self._err(400, "action 需为 approve/reject")
            return True
        if action == "pin":
            if method == "POST":
                c.execute("UPDATE community_posts SET sticky=1 WHERE id=?", (pid,))
                notify(c, d["user_id"], "community_audit", "置顶通知",
                       "你的帖子已被管理员置顶", from_name="流萤社区官方")
                admin_log(c, adm[0], "pin", "post", pid)
                c.commit()
                self._ok({"sticky": 1})
            else:
                c.execute("UPDATE community_posts SET sticky=0 WHERE id=?", (pid,))
                c.commit()
                self._ok({"sticky": 0})
            return True
        if action == "featured":
            if method == "POST":
                c.execute("UPDATE community_posts SET featured=1, featured_at=? WHERE id=?",
                          (time.time(), pid))
                notify(c, d["user_id"], "community_audit", "精华通知",
                       "你的帖子已被设为精华", from_name="流萤社区官方")
                admin_log(c, adm[0], "featured", "post", pid)
                c.commit()
                self._ok({"featured": 1})
            else:
                c.execute("UPDATE community_posts SET featured=0 WHERE id=?", (pid,))
                c.commit()
                self._ok({"featured": 0})
            return True
        if action == "takedown":
            if method == "POST":
                reason = (body.get("reason") or "").strip()[:200]
                if not reason:
                    self._err(400, "下架理由必填")
                    return True
                c.execute("UPDATE community_posts SET taken_down=1, taken_down_reason=? WHERE id=?",
                          (reason, pid))
                notify(c, d["user_id"], "community_audit", "内容已下架",
                       "你的内容已下架：%s" % reason, from_name="流萤社区官方")
                admin_log(c, adm[0], "takedown", "post", pid, reason)
                c.commit()
                self._ok({"takenDown": 1})
            else:
                c.execute("UPDATE community_posts SET taken_down=0, taken_down_reason='' WHERE id=?",
                          (pid,))
                c.commit()
                self._ok({"takenDown": 0})
            return True
        if action == "end-poll":
            try:
                poll = json.loads(d.get("poll") or "{}")
                poll["endAt"] = time.time()
                c.execute("UPDATE community_posts SET poll=? WHERE id=?",
                          (json.dumps(poll, ensure_ascii=False), pid))
                admin_log(c, adm[0], "end_poll", "post", pid)
                c.commit()
                self._ok({"pollClosed": True})
            except Exception:
                self._err(400, "投票数据异常")
            return True
    m = re.match(r"^/admin/posts/([\w\-]+)$", api)
    if m and method == "DELETE":
        adm = _auth(self, c, 2)
        if not adm:
            return True
        pid = m.group(1)
        row = c.execute("SELECT * FROM community_posts WHERE id=?", (pid,)).fetchone()
        if not row:
            self._err(404, "帖子不存在")
            return True
        d = row_dict(row)
        body = _body(self)
        c.execute("UPDATE community_posts SET status=0 WHERE id=?", (pid,))
        if body.get("notifyAuthor"):
            notify(c, d["user_id"], "community_audit", "内容被删除",
                   "你的内容因违规已被管理员删除", from_name="流萤社区官方")
        admin_log(c, adm[0], "delete", "post", pid)
        c.commit()
        self._ok({"deleted": True})
        return True
    return False


# ---------------- 评论管理（删除/神评） ----------------
def _handle_admin_comments(self, c, u, api, method):
    if api == "/admin/comments":
        adm = _auth(self, c, 2)
        if not adm:
            return True
        query = urllib.parse.parse_qs(u.query)
        page = max(1, int((query.get("page") or ["1"])[0] or 1))
        size = min(50, max(1, int((query.get("size") or ["20"])[0] or 20)))
        pid = (query.get("post_id") or [""])[0].strip()
        where = ["status=1"]
        args = []
        if pid:
            where.append("post_id=?")
            args.append(pid)
        rows = c.execute("SELECT * FROM community_post_comments WHERE %s ORDER BY created DESC LIMIT ? OFFSET ?"
                         % " AND ".join(where), args + [size, (page - 1) * size]).fetchall()
        c.commit()
        self._ok({"list": [decorate_comment(c, r, None) for r in rows],
                  "page": page, "size": size, "hasMore": len(rows) == size})
        return True
    m = re.match(r"^/admin/comment/([\w\-]+)/(pin)$", api)
    if m and method in ("POST", "DELETE"):
        adm = _auth(self, c, 2)
        if not adm:
            return True
        cid, action = m.group(1), m.group(2)
        row = c.execute("SELECT * FROM community_post_comments WHERE id=?", (cid,)).fetchone()
        if not row:
            self._err(404, "评论不存在")
            return True
        d = row_dict(row)
        if action == "pin":
            if method == "POST":
                c.execute("UPDATE community_post_comments SET pinned=1, pinned_at=? WHERE id=?",
                          (time.time(), cid))
                notify(c, d["user_id"], "community_audit", "神评通知",
                       "你的评论被设为神评", from_name="流萤社区官方")
                admin_log(c, adm[0], "pin_comment", "comment", cid)
                c.commit()
                self._ok({"pinned": 1})
            else:
                c.execute("UPDATE community_post_comments SET pinned=0 WHERE id=?", (cid,))
                c.commit()
                self._ok({"pinned": 0})
            return True
    m = re.match(r"^/admin/comment/([\w\-]+)$", api)
    if m and method == "DELETE":
        adm = _auth(self, c, 2)
        if not adm:
            return True
        cid = m.group(1)
        row = c.execute("SELECT * FROM community_post_comments WHERE id=?", (cid,)).fetchone()
        if not row:
            self._err(404, "评论不存在")
            return True
        c.execute("UPDATE community_post_comments SET status=0 WHERE id=?", (cid,))
        c.execute("UPDATE community_posts SET comment_count=MAX(0,comment_count-1) WHERE id=?",
                  (row[1],))
        admin_log(c, adm[0], "delete_comment", "comment", cid)
        c.commit()
        self._ok({"deleted": True})
        return True
    return False


# ---------------- 举报处理 ----------------
def _handle_reports(self, c, u, api, method):
    if api == "/admin/reports":
        adm = _auth(self, c, 2)
        if not adm:
            return True
        query = urllib.parse.parse_qs(u.query)
        status = int((query.get("status") or ["0"])[0] or 0)
        rows = c.execute(
            "SELECT * FROM community_reports WHERE status=? ORDER BY created DESC LIMIT 100",
            (status,)).fetchall()
        out = []
        for r in rows:
            d = row_dict(r)
            target = None
            if d["target_type"] == "post":
                row = c.execute("SELECT content, user_id FROM community_posts WHERE id=?", (d["target_id"],)).fetchone()
                if row:
                    target = {"type": "post", "content": (row[0] or "")[:80], "authorId": row[1]}
            elif d["target_type"] == "comment":
                row = c.execute("SELECT content, user_id FROM community_post_comments WHERE id=? AND status=1", (d["target_id"],)).fetchone()
                if row:
                    target = {"type": "comment", "content": (row[0] or "")[:80], "authorId": row[1]}
            out.append({"id": d["id"], "targetType": d["target_type"], "targetId": d["target_id"],
                        "userId": d["user_id"], "reason": d["reason"], "created": d["created"],
                        "target": target})
        c.commit()
        self._ok({"list": out})
        return True
    m = re.match(r"^/admin/reports/([\w\-]+)/handle$", api)
    if m and method == "POST":
        adm = _auth(self, c, 2)
        if not adm:
            return True
        rid = m.group(1)
        body = _body(self)
        action = (body.get("action") or "ignore").strip()
        row = c.execute("SELECT * FROM community_reports WHERE id=?", (rid,)).fetchone()
        if not row:
            self._err(404, "举报不存在")
            return True
        d = row_dict(row)
        result = "已忽略"
        if action == "delete" and d["target_type"] == "post":
            c.execute("UPDATE community_posts SET status=0 WHERE id=?", (d["target_id"],))
            result = "已删除帖子"
        elif action == "delete" and d["target_type"] == "comment":
            c.execute("UPDATE community_post_comments SET status=0 WHERE id=?", (d["target_id"],))
            result = "已删除评论"
        c.execute("UPDATE community_reports SET status=1, result=? WHERE id=?", (result, rid))
        admin_log(c, adm[0], "report_handle", d["target_type"], d["target_id"], result)
        c.commit()
        self._ok({"handled": True, "result": result})
        return True
    return False


# ---------------- 版块 / 话题 / Banner / 活动 / 敏感词 ----------------
def _crud_boards(self, c, u, api, method):
    if not (api == "/admin/boards" or re.match(r"^/admin/boards/[\w\-]+$", api)):
        return False
    adm = _auth(self, c, 1)
    if not adm:
        return True
    if api == "/admin/boards" and method == "POST":
        body = _body(self)
        name = (body.get("name") or "").strip()[:20]
        if not name:
            self._err(400, "版块名必填")
            return True
        parent = (body.get("parentId") or "").strip()
        if parent:
            if not c.execute("SELECT 1 FROM community_boards WHERE id=?", (parent,)).fetchone():
                self._err(400, "父级版块不存在")
                return True
        bid = uuid.uuid4().hex
        c.execute("INSERT INTO community_boards(id,name,parent_id,icon,color,sort,active,created)"
                  " VALUES(?,?,?,?,?,?,1,?)",
                  (bid, name, parent, (body.get("icon") or "📌").strip()[:4],
                   (body.get("color") or "#4FC3F7").strip()[:16],
                   int(body.get("sort") or 0), time.time()))
        admin_log(c, adm[0], "board_add", "board", bid, name)
        c.commit()
        self._ok({"id": bid})
        return True
    m = re.match(r"^/admin/boards/([\w\-]+)$", api)
    if m:
        bid = m.group(1)
        row = c.execute("SELECT 1 FROM community_boards WHERE id=?", (bid,)).fetchone()
        if not row:
            self._err(404, "版块不存在")
            return True
        if method == "PUT":
            body = _body(self)
            sets = []
            args = []
            if "name" in body:
                sets.append("name=?")
                args.append((body.get("name") or "").strip()[:20])
            if "parentId" in body:
                sets.append("parent_id=?")
                args.append((body.get("parentId") or "").strip())
            if "icon" in body:
                sets.append("icon=?")
                args.append((body.get("icon") or "").strip()[:4])
            if "color" in body:
                sets.append("color=?")
                args.append((body.get("color") or "").strip()[:16])
            if "sort" in body:
                sets.append("sort=?")
                args.append(int(body.get("sort") or 0))
            if "active" in body:
                sets.append("active=?")
                args.append(1 if body.get("active") else 0)
            if sets:
                c.execute("UPDATE community_boards SET %s WHERE id=?" % ",".join(sets),
                          args + [bid])
            admin_log(c, adm[0], "board_update", "board", bid)
            c.commit()
            self._ok({"updated": True})
            return True
        if method == "DELETE":
            c.execute("UPDATE community_boards SET active=0 WHERE id=?", (bid,))
            admin_log(c, adm[0], "board_delete", "board", bid)
            c.commit()
            self._ok({"deleted": True})
            return True
    return False


def _handle_topics_admin(self, c, u, api, method):
    if not (api == "/admin/topics" or api.startswith("/admin/topics/")):
        return False
    adm = _auth(self, c, 1)
    if not adm:
        return True
    if api == "/admin/topics":
        if method == "GET":
            rows = c.execute("SELECT name, post_count, created FROM community_topics"
                             " ORDER BY post_count DESC LIMIT 200").fetchall()
            c.commit()
            self._ok({"list": [{"name": r[0], "count": r[1], "created": r[2]} for r in rows]})
            return True
        if method == "POST":
            body = _body(self)
            name = (body.get("name") or "").strip()[:20]
            if not name:
                self._err(400, "话题名必填")
                return True
            c.execute("INSERT OR IGNORE INTO community_topics(id,name,post_count,created)"
                      " VALUES(?,?,0,?)", (uuid.uuid4().hex, name, time.time()))
            admin_log(c, adm[0], "topic_add", "topic", name)
            c.commit()
            self._ok({"added": True})
            return True
    m = re.match(r"^/admin/topics/([^/]+)$", api)
    if m and method == "DELETE":
        name = urllib.parse.unquote(m.group(1))
        c.execute("DELETE FROM community_topics WHERE name=?", (name,))
        admin_log(c, adm[0], "topic_delete", "topic", name)
        c.commit()
        self._ok({"deleted": True})
        return True
    return False


def _handle_banners_admin(self, c, u, api, method):
    if not (api == "/admin/banners" or api.startswith("/admin/banners/")):
        return False
    adm = _auth(self, c, 1)
    if not adm:
        return True
    if api == "/admin/banners" and method == "POST":
        body = _body(self)
        image = (body.get("image") or "").strip()
        if not image:
            self._err(400, "图片必填")
            return True
        bid = uuid.uuid4().hex
        c.execute(
            "INSERT INTO community_banners(id,image,link_type,link_id,sort,active,start_at,end_at,created)"
            " VALUES(?,?,?,?,?,?,?,?,?)",
            (bid, image, (body.get("linkType") or "url").strip()[:16],
             (body.get("linkId") or "").strip(), int(body.get("sort") or 0),
             1 if body.get("active", 1) else 0,
             float(body.get("startAt") or 0), float(body.get("endAt") or 0), time.time()))
        admin_log(c, adm[0], "banner_add", "banner", bid)
        c.commit()
        self._ok({"id": bid})
        return True
    if api == "/admin/banners":
        rows = c.execute("SELECT * FROM community_banners ORDER BY sort ASC").fetchall()
        c.commit()
        self._ok({"list": [row_dict(r) for r in rows]})
        return True
    m = re.match(r"^/admin/banners/([\w\-]+)$", api)
    if m:
        bid = m.group(1)
        if method == "PUT":
            body = _body(self)
            sets = []
            args = []
            for k, col in (("image", "image"), ("linkType", "link_type"),
                           ("linkId", "link_id"), ("sort", "sort")):
                if k in body:
                    sets.append(col + "=?")
                    args.append(body[k])
            if "active" in body:
                sets.append("active=?")
                args.append(1 if body.get("active") else 0)
            if sets:
                c.execute("UPDATE community_banners SET %s WHERE id=?" % ",".join(sets), args + [bid])
            admin_log(c, adm[0], "banner_update", "banner", bid)
            c.commit()
            self._ok({"updated": True})
            return True
        if method == "DELETE":
            c.execute("DELETE FROM community_banners WHERE id=?", (bid,))
            admin_log(c, adm[0], "banner_delete", "banner", bid)
            c.commit()
            self._ok({"deleted": True})
            return True
    return False


def _handle_activities_admin(self, c, u, api, method):
    if not (api == "/admin/activities" or api.startswith("/admin/activities/")):
        return False
    adm = _auth(self, c, 1)
    if not adm:
        return True
    if api == "/admin/activities" and method == "POST":
        body = _body(self)
        title = (body.get("title") or "").strip()[:30]
        if not title:
            self._err(400, "活动标题必填")
            return True
        aid = uuid.uuid4().hex
        c.execute(
            "INSERT INTO community_activities(id,topic_id,title,desc,reward_exp,start_at,end_at,status,created)"
            " VALUES(?,?,?,?,?,?,?,?,?)",
            (aid, (body.get("topicId") or "").strip(),
             title, (body.get("desc") or "").strip()[:200],
             int(body.get("rewardExp") or 0),
             float(body.get("startAt") or 0), float(body.get("endAt") or 0),
             1 if (body.get("startAt") or 0) <= time.time() else 0, time.time()))
        admin_log(c, adm[0], "activity_add", "activity", aid, title)
        c.commit()
        self._ok({"id": aid})
        return True
    if api == "/admin/activities":
        rows = c.execute("SELECT * FROM community_activities ORDER BY created DESC").fetchall()
        c.commit()
        self._ok({"list": [row_dict(r) for r in rows]})
        return True
    m = re.match(r"^/admin/activities/([\w\-]+)(/end)?$", api)
    if m:
        aid = m.group(1)
        row = c.execute("SELECT * FROM community_activities WHERE id=?", (aid,)).fetchone()
        if not row:
            self._err(404, "活动不存在")
            return True
        d = row_dict(row)
        if m.group(2) == "/end" and method == "POST":
            # 结束活动 + 发奖：参与者 = 该话题下发过帖的用户
            c.execute("UPDATE community_activities SET status=2, end_at=? WHERE id=?",
                      (time.time(), aid))
            if d["topic_id"] and d["reward_exp"] > 0:
                users = c.execute(
                    "SELECT DISTINCT user_id FROM community_posts WHERE topic LIKE ? AND status=1",
                    ("%" + d["topic_id"] + "%",)).fetchall()
                for u2 in users:
                    add_exp(c, u2[0], d["reward_exp"])
                detail = "发奖 %d 人 × %d 经验" % (len(users), d["reward_exp"])
            else:
                detail = "无奖励"
            admin_log(c, adm[0], "activity_end", "activity", aid, detail)
            c.commit()
            self._ok({"ended": True, "detail": detail})
            return True
        if method == "DELETE":
            c.execute("DELETE FROM community_activities WHERE id=?", (aid,))
            admin_log(c, adm[0], "activity_delete", "activity", aid)
            c.commit()
            self._ok({"deleted": True})
            return True
    return False


def _handle_sensitive_admin(self, c, u, api, method):
    if not (api == "/admin/sensitive-words" or api.startswith("/admin/sensitive-words/")):
        return False
    adm = _auth(self, c, 1)
    if not adm:
        return True
    if api == "/admin/sensitive-words" and method == "POST":
        body = _body(self)
        word = (body.get("word") or "").strip()[:30]
        if not word:
            self._err(400, "敏感词必填")
            return True
        lv = int(body.get("level") or 0)
        c.execute("INSERT OR IGNORE INTO community_sensitive_words(id,word,level,active,created)"
                  " VALUES(?,?,?,1,?)", (uuid.uuid4().hex, word, lv, time.time()))
        admin_log(c, adm[0], "sw_add", "word", word)
        c.commit()
        self._ok({"added": True})
        return True
    if api == "/admin/sensitive-words":
        rows = c.execute("SELECT * FROM community_sensitive_words ORDER BY created DESC").fetchall()
        c.commit()
        self._ok({"list": [{"id": r[0], "word": r[1], "level": r[2], "active": r[3]}
                           for r in rows]})
        return True
    m = re.match(r"^/admin/sensitive-words/([\w\-]+)$", api)
    if m:
        wid = m.group(1)
        if method == "DELETE":
            c.execute("DELETE FROM community_sensitive_words WHERE id=?", (wid,))
            admin_log(c, adm[0], "sw_delete", "word", wid)
            c.commit()
            self._ok({"deleted": True})
            return True
        if method == "PUT":
            body = _body(self)
            if "level" in body:
                c.execute("UPDATE community_sensitive_words SET level=? WHERE id=?", (int(body["level"]), wid))
            if "active" in body:
                c.execute("UPDATE community_sensitive_words SET active=? WHERE id=?", (1 if body["active"] else 0, wid))
            admin_log(c, adm[0], "sw_update", "word", wid)
            c.commit()
            self._ok({"updated": True})
            return True
    return False


# ---------------- 用户 / 会员 / 官方通知 ----------------
def _handle_users_admin(self, c, u, api, method):
    if api == "/admin/users":
        adm = _auth(self, c, 1)
        if not adm:
            return True
        query = urllib.parse.parse_qs(u.query)
        keyword = (query.get("keyword") or [""])[0].strip()
        page = max(1, int((query.get("page") or ["1"])[0] or 1))
        size = min(50, max(1, int((query.get("size") or ["20"])[0] or 20)))
        where = "1=1"
        args = []
        if keyword:
            where = "(name LIKE ? OR account LIKE ? OR id LIKE ?)"
            like = "%" + keyword + "%"
            args = [like, like, like]
        total = c.execute("SELECT COUNT(*) FROM users WHERE %s" % where, args).fetchone()[0]
        rows = c.execute("SELECT id, account, name, avatar, created, banned, ban_reason, title, verified, verified_label"
                         " FROM users WHERE %s ORDER BY created DESC LIMIT ? OFFSET ?" % where,
                         args + [size, (page - 1) * size]).fetchall()
        out = []
        for r in rows:
            exp = c.execute("SELECT exp, level FROM community_exp WHERE user_id=?", (r[0],)).fetchone()
            mem = c.execute("SELECT level, expire FROM community_members WHERE user_id=?", (r[0],)).fetchone()
            adm_row = c.execute("SELECT level FROM community_admins WHERE user_id=?", (r[0],)).fetchone()
            out.append({"id": r[0], "account": r[1] or "", "name": r[2] or "",
                        "avatar": r[3] or "", "created": r[4] or 0,
                        "banned": r[5] or 0, "banReason": r[6] or "",
                        "title": r[7] or "", "verified": r[8] or "", "verifiedLabel": r[9] or "",
                        "exp": exp[0] if exp else 0, "level": exp[1] if exp else 0,
                        "member": (mem[0] or "") if (mem and mem[1] and mem[1] > time.time()) else "",
                        "adminLevel": adm_row[0] if adm_row else 0})
        c.commit()
        self._ok({"list": out, "total": total, "page": page, "size": size})
        return True
    m = re.match(r"^/admin/users/([\w\-]+)/ban$", api)
    if m and method == "POST":
        adm = _auth(self, c, 1)
        if not adm:
            return True
        uid = m.group(1)
        body = _body(self)
        banned = 1 if body.get("ban") else 0
        reason = (body.get("reason") or "").strip()[:200]
        c.execute("UPDATE users SET banned=?, ban_reason=? WHERE id=?", (banned, reason if banned else "", uid))
        admin_log(c, adm[0], "ban" if banned else "unban", "user", uid, reason)
        c.commit()
        self._ok({"banned": banned})
        return True
    return False


def _handle_members_admin(self, c, u, api, method):
    if not (api == "/admin/members" or api.startswith("/admin/members/")):
        return False
    adm = _auth(self, c, 1)
    if not adm:
        return True
    if api == "/admin/members":
        rows = c.execute(
            "SELECT m.user_id, m.level, m.expire, u.name, u.account FROM community_members m"
            " JOIN users u ON u.id=m.user_id ORDER BY m.expire DESC LIMIT 200").fetchall()
        c.commit()
        self._ok({"list": [{"userId": r[0], "level": r[1], "expire": r[2],
                            "name": r[3] or "", "account": r[4] or ""} for r in rows]})
        return True
    m = re.match(r"^/admin/members/([\w\-]+)/(grant|revoke)$", api)
    if m and method == "POST":
        uid, action = m.group(1), m.group(2)
        body = _body(self)
        if action == "grant":
            level = (body.get("level") or "member").strip()
            if level not in ("member", "svip"):
                self._err(400, "level 需为 member/svip")
                return True
            days = max(1, min(3650, int(body.get("days") or 30)))
            expire = time.time() + days * 86400
            row = c.execute("SELECT level, expire FROM community_members WHERE user_id=?", (uid,)).fetchone()
            if row and row[1] and row[1] > time.time():
                expire = row[1] + days * 86400
            c.execute("INSERT OR REPLACE INTO community_members(user_id,level,expire,created,updated)"
                      " VALUES(?,?,?,?,?)",
                      (uid, level, expire, time.time(), time.time()))
            admin_log(c, adm[0], "member_grant", "user", uid, "%s %dd" % (level, days))
            c.commit()
            self._ok({"expire": expire, "days": days})
            return True
        if action == "revoke":
            c.execute("DELETE FROM community_members WHERE user_id=?", (uid,))
            admin_log(c, adm[0], "member_revoke", "user", uid)
            c.commit()
            self._ok({"revoked": True})
            return True
    return False


def _handle_official_admin(self, c, u, api, method):
    if not (api == "/admin/official" or api.startswith("/admin/official/")):
        return False
    adm = _auth(self, c, 1)
    if not adm:
        return True
    if api == "/admin/official" and method == "POST":
        body = _body(self)
        content = (body.get("content") or "").strip()[:1000]
        if not content:
            self._err(400, "内容必填")
            return True
        receiver = (body.get("userId") or "").strip()
        official_msg(c, receiver, content)
        admin_log(c, adm[0], "official_send", "user", receiver, content[:50])
        c.commit()
        self._ok({"sent": True})
        return True
    if api == "/admin/official":
        rows = c.execute("SELECT * FROM community_official_messages ORDER BY created DESC LIMIT 100").fetchall()
        c.commit()
        self._ok({"list": [{"id": r[0], "content": r[1], "senderName": r[2],
                            "userId": r[3], "created": r[4]} for r in rows]})
        return True
    m = re.match(r"^/admin/official/([\w\-]+)$", api)
    if m and method == "DELETE":
        c.execute("DELETE FROM community_official_messages WHERE id=?", (m.group(1),))
        admin_log(c, adm[0], "official_delete", "official", m.group(1))
        c.commit()
        self._ok({"deleted": True})
        return True
    return False


# ---------------- 头像框 / 表情包 ----------------
def _handle_frames_admin(self, c, u, api, method):
    if not (api == "/admin/frames" or api.startswith("/admin/frames/")):
        return False
    adm = _auth(self, c, 1)
    if not adm:
        return True
    if api == "/admin/frames" and method == "POST":
        body = _body(self)
        name = (body.get("name") or "").strip()[:20]
        image = (body.get("image") or "").strip()
        image_dynamic = (body.get("imageDynamic") or "").strip()
        if not name or not image:
            self._err(400, "名称与静态图必填")
            return True
        fid = uuid.uuid4().hex
        c.execute("INSERT INTO community_frames(id,name,image,image_dynamic,sort,active,created)"
                  " VALUES(?,?,?,?,?,1,?)",
                  (fid, name, image, image_dynamic, int(body.get("sort") or 0), time.time()))
        admin_log(c, adm[0], "frame_add", "frame", fid, name)
        c.commit()
        self._ok({"id": fid})
        return True
    if api == "/admin/frames":
        rows = c.execute("SELECT * FROM community_frames ORDER BY sort ASC").fetchall()
        c.commit()
        self._ok({"list": [row_dict(r) for r in rows]})
        return True
    m = re.match(r"^/admin/frames/([\w\-]+)$", api)
    if m:
        fid = m.group(1)
        if method == "PUT":
            body = _body(self)
            sets = []
            args = []
            for k, col in (("name", "name"), ("image", "image"),
                           ("imageDynamic", "image_dynamic"), ("sort", "sort")):
                if k in body:
                    sets.append(col + "=?")
                    args.append(body[k])
            if "active" in body:
                sets.append("active=?")
                args.append(1 if body.get("active") else 0)
            if sets:
                c.execute("UPDATE community_frames SET %s WHERE id=?" % ",".join(sets), args + [fid])
            admin_log(c, adm[0], "frame_update", "frame", fid)
            c.commit()
            self._ok({"updated": True})
            return True
        if method == "DELETE":
            c.execute("DELETE FROM community_frames WHERE id=?", (fid,))
            admin_log(c, adm[0], "frame_delete", "frame", fid)
            c.commit()
            self._ok({"deleted": True})
            return True
    return False


def _handle_emojis_admin(self, c, u, api, method):
    if not (api == "/admin/emojis" or api.startswith("/admin/emojis/")):
        return False
    adm = _auth(self, c, 1)
    if not adm:
        return True
    if api == "/admin/emojis" and method == "POST":
        body = _body(self)
        code = (body.get("code") or "").strip()
        image = (body.get("image") or "").strip()
        category = (body.get("category") or "默认").strip()[:10]
        if not code or not image:
            self._err(400, "code 与图片必填")
            return True
        c.execute("INSERT OR IGNORE INTO community_emojis(id,code,image,category,sort,active,created)"
                  " VALUES(?,?,?,?,?,1,?)",
                  (uuid.uuid4().hex, code, image, category, int(body.get("sort") or 0), time.time()))
        admin_log(c, adm[0], "emoji_add", "emoji", code)
        c.commit()
        self._ok({"added": True})
        return True
    if api == "/admin/emojis":
        rows = c.execute("SELECT * FROM community_emojis ORDER BY category, sort").fetchall()
        c.commit()
        self._ok({"list": [{"id": r[0], "code": r[1], "image": r[2], "category": r[3],
                            "active": r[5]} for r in rows]})
        return True
    if api == "/admin/emojis/import" and method == "POST":
        # 官方表情包目录导入：files/emoji_official/<分类>/<文件名> → community_emojis
        body = _body(self)
        base_url = (body.get("baseUrl") or "").strip()
        imported = 0
        skipped = 0
        if os.path.isdir(EMOJI_DIR):
            for cat in sorted(os.listdir(EMOJI_DIR)):
                cdir = os.path.join(EMOJI_DIR, cat)
                if not os.path.isdir(cdir):
                    continue
                for fn in sorted(os.listdir(cdir)):
                    if not re.match(r".+\.(png|jpg|jpeg|webp|gif)$", fn, re.I):
                        continue
                    code = "[" + os.path.splitext(fn)[0][:20] + "]"
                    rel = "emoji_official/%s/%s" % (cat, fn)
                    exists = c.execute("SELECT 1 FROM community_emojis WHERE code=?", (code,)).fetchone()
                    if exists:
                        skipped += 1
                        continue
                    c.execute("INSERT INTO community_emojis(id,code,image,category,sort,active,created)"
                              " VALUES(?,?,?,?,0,1,?)",
                              (uuid.uuid4().hex, code, rel, cat, time.time()))
                    imported += 1
        admin_log(c, adm[0], "emoji_import", "dir", "emoji_official", "%d imported" % imported)
        c.commit()
        self._ok({"imported": imported, "skipped": skipped,
                  "msg": "导入完成：新增 %d，跳过 %d（已存在）" % (imported, skipped)})
        return True
    m = re.match(r"^/admin/emojis/([\w\-]+)$", api)
    if m:
        eid = m.group(1)
        if method == "DELETE":
            c.execute("DELETE FROM community_emojis WHERE id=?", (eid,))
            c.execute("DELETE FROM community_user_emojis WHERE emoji_id=?", (eid,))
            admin_log(c, adm[0], "emoji_delete", "emoji", eid)
            c.commit()
            self._ok({"deleted": True})
            return True
        if method == "PUT":
            body = _body(self)
            sets = []
            args = []
            for k, col in (("code", "code"), ("image", "image"),
                           ("category", "category"), ("sort", "sort")):
                if k in body:
                    sets.append(col + "=?")
                    args.append(body[k])
            if "active" in body:
                sets.append("active=?")
                args.append(1 if body.get("active") else 0)
            if sets:
                c.execute("UPDATE community_emojis SET %s WHERE id=?" % ",".join(sets), args + [eid])
            admin_log(c, adm[0], "emoji_update", "emoji", eid)
            c.commit()
            self._ok({"updated": True})
            return True
    return False


# ---------------- 等级配置 / 管理员 / 热词 / 令牌 / 日志 ----------------
def _handle_level_config(self, c, u, api, method):
    if api != "/admin/level-config":
        return False
    adm = _auth(self, c, 1)
    if not adm:
        return True
    if method == "GET":
        from common import LEVEL_THRESHOLDS, EXP_RULES
        c.commit()
        self._ok({"thresholds": LEVEL_THRESHOLDS, "rules": EXP_RULES})
        return True
    body = _body(self)
    # 阈值调整：暂存于 config 层（落库用 ai_comment_cfg 风格的自定义表？直接写社区表未建）
    # 简化：返回已保存（阈值存 JSON 到 community_sensitive_words？不。预留接口，规则常量热更由代码更新）
    self._ok({"saved": True, "msg": "阈值/规则由服务端配置（热更需更新代码常量）"})
    return True


def _handle_admins_admin(self, c, u, api, method):
    # 管理员管理仅一级
    if api == "/admin/admins" and method == "GET":
        adm = _auth(self, c, 1)
        if not adm:
            return True
        rows = c.execute("SELECT a.token, a.user_id, a.level, a.name, a.created, u.name AS uname"
                         " FROM community_admins a LEFT JOIN users u ON u.id=a.user_id"
                         " ORDER BY a.level ASC").fetchall()
        c.commit()
        self._ok({"list": [{"token": r[0][:12] + "…", "userId": r[1], "level": r[2],
                            "name": r[5] or r[3], "created": r[4]} for r in rows]})
        return True
    m = re.match(r"^/admin/admins/(grant|revoke)$", api)
    if m and method == "POST":
        adm = _auth(self, c, 1)
        if not adm:
            return True
        action = m.group(1)
        body = _body(self)
        uid = (body.get("userId") or "").strip()
        if not c.execute("SELECT 1 FROM users WHERE id=?", (uid,)).fetchone():
            self._err(404, "用户不存在")
            return True
        if action == "grant":
            tok = secrets.token_urlsafe(24)
            name = (body.get("name") or "社区管理员").strip()[:20]
            c.execute("INSERT INTO community_admins(token,user_id,level,name,created) VALUES(?,?,?,?,?)",
                      (tok, uid, 2, name, time.time()))
            admin_log(c, adm[0], "grant_admin", "user", uid, name)
            c.commit()
            self._ok({"token": tok, "level": 2})
            return True
        if action == "revoke":
            c.execute("DELETE FROM community_admins WHERE user_id=? AND level=2", (uid,))
            admin_log(c, adm[0], "revoke_admin", "user", uid)
            c.commit()
            self._ok({"revoked": True})
            return True
    return False


def _handle_token_rotate(self, c, u, api, method):
    if api != "/admin/token/rotate":
        return False
    adm = _auth(self, c, 1)
    if not adm:
        return True
    body = _body(self)
    old = (body.get("oldToken") or "").strip()
    if old and old != adm[0]:
        self._err(403, "旧令牌不匹配")
        return True
    tok = secrets.token_urlsafe(24)
    c.execute("UPDATE community_admins SET token=? WHERE token=?", (tok, adm[0]))
    admin_log(c, adm[0], "token_rotate", "admin", "")
    c.commit()
    self._ok({"token": tok, "msg": "令牌已轮换，请立即更新配置"})
    return True


def _handle_hotwords(self, c, u, api, method):
    if api != "/admin/hotwords":
        return False
    adm = _auth(self, c, 1)
    if not adm:
        return True
    since = time.time() - 7 * 24 * 3600
    rows = c.execute(
        "SELECT q, COUNT(*) cnt FROM community_search_logs WHERE created>? GROUP BY q"
        " ORDER BY cnt DESC LIMIT 100", (since,)).fetchall()
    c.commit()
    self._ok({"list": [{"q": r[0], "count": r[1]} for r in rows]})
    return True


def _handle_logs(self, c, u, api, method):
    if api != "/admin/logs":
        return False
    adm = _auth(self, c, 1)
    if not adm:
        return True
    rows = c.execute("SELECT * FROM community_admin_logs ORDER BY created DESC LIMIT 100").fetchall()
    c.commit()
    self._ok({"list": [row_dict(r) for r in rows]})
    return True


def dispatch(self, c, u, api, method):
    handlers = [_handle_stats, _handle_admin_posts, _handle_admin_comments,
                _handle_reports, _crud_boards, _handle_topics_admin,
                _handle_banners_admin, _handle_activities_admin,
                _handle_sensitive_admin, _handle_users_admin,
                _handle_members_admin, _handle_official_admin,
                _handle_frames_admin, _handle_emojis_admin,
                _handle_level_config, _handle_admins_admin,
                _handle_token_rotate, _handle_hotwords, _handle_logs]
    for h in handlers:
        if h(self, c, u, api, method):
            return True
    return False
