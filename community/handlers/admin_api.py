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

import epay
import invite_core
from core.settings import settings
from common import (db, rate_limit, admin_required, admin_log, notify, row_dict,
                    official_msg, add_exp, task_progress, FILES_DIR,
                    image_magic_ok, decorate_post, decorate_comment, bump_board_count)
from rich_text import sanitize_official_rich

EMOJI_DIR = os.path.join(FILES_DIR, "emoji_official")

# 管理端图片上传（Banner 等运营位素材）
MAX_ADMIN_IMAGE = 10 * 1024 * 1024      # 10MB
ADMIN_IMG_EXT = (".png", ".jpg", ".jpeg", ".webp", ".gif")

# ---------------- 管理员角色与模块权限 ----------------
# 三级：super（超级管理员，唯一）> admin（管理员）> auditor（审核员）
# 可勾选授权的模块（超管天然拥有全部；admins/system 仅超管）
ADMIN_MODULES = ("content", "comments", "users", "ops", "data", "feedback", "apps")
SUPER_ONLY_MODULES = ("admins", "system")
MODULE_LABELS = {
    "content": "内容审核（帖子/视频/举报）",
    "comments": "评论管理",
    "users": "用户处置（封禁/会员）",
    "ops": "运营配置（Banner/话题/活动/敏感词/装扮/官网）",
    "data": "数据看板（统计/热词）",
    "feedback": "用户反馈",
    "apps": "应用市场（投稿/审核/分类/评论）",
    "admins": "管理员管理（仅超管）",
    "system": "令牌/日志（仅超管）",
}

_PREFIX_MODULE = [
    ("/admin/admins", "admins"),
    ("/admin/token", "system"),
    ("/admin/logs", "system"),
    ("/admin/hotwords", "system"),
    ("/admin/posts", "content"),
    ("/admin/post", "content"),
    ("/admin/videos", "content"),
    ("/admin/reports", "content"),
    ("/admin/comments", "comments"),
    ("/admin/users", "users"),
    ("/admin/ban", "users"),
    ("/admin/members", "users"),
    ("/admin/member/", "users"),
    ("/admin/site", "ops"),
    ("/admin/app-releases", "ops"),
    ("/admin/hot-update", "ops"),
    ("/admin/upload-package", "ops"),
    ("/admin/banner-settings", "ops"),
    ("/admin/banners", "ops"),
    ("/admin/topics", "ops"),
    ("/admin/activities", "ops"),
    ("/admin/sensitive", "ops"),
    ("/admin/official", "ops"),
    ("/admin/frames", "ops"),
    ("/admin/emojis", "ops"),
    ("/admin/levels", "ops"),
    ("/admin/level-config", "ops"),
    ("/admin/upload-image", "ops"),
    ("/admin/feedback", "feedback"),
    ("/admin/apps", "apps"),
    ("/admin/app-categories", "apps"),
    ("/admin/app-comments", "apps"),
    ("/admin/app-reports", "apps"),
    ("/admin/stats", "data"),
]


def _module_of(api):
    for pre, mod in _PREFIX_MODULE:
        if api.startswith(pre):
            return mod
    return "system"   # 未登记的接口默认只有超管能访问


def _who(c, handler):
    """返回 (token, level, role, perms, name) 或 None。

    兼容 H5 头部 X-Community-Admin-Token 与 App 登录 token（按 user_id 查表）。
    """
    tok = handler.headers.get("X-Community-Admin-Token", "").strip()
    if tok:
        row = c.execute(
            "SELECT token, level, COALESCE(role,''), COALESCE(perms,''), COALESCE(name,'')"
            " FROM community_admins WHERE token=?", (tok,)).fetchone()
        if row:
            return row
    from common import resolve_token
    uid = resolve_token(c, handler.headers.get("Authorization", ""))
    if uid:
        row = c.execute(
            "SELECT token, level, COALESCE(role,''), COALESCE(perms,''), COALESCE(name,'')"
            " FROM community_admins WHERE user_id=?", (uid,)).fetchone()
        if row:
            return row
    return None


def _role_of(row):
    role = (row[2] or "").strip()
    if role in ("super", "admin", "auditor"):
        return role
    return "super" if (row[1] or 2) == 1 else "auditor"


def _perms_of(row):
    return [x for x in (row[3] or "").split(",") if x]


def _authed(c, handler):
    """身份 + 模块级鉴权。通过返回 (token, role, perms)；不通过已回响应并返回 None。"""
    row = _who(c, handler)
    if not row:
        handler._err(401, "管理员令牌无效")
        return None
    role = _role_of(row)
    perms = _perms_of(row)
    api = urllib.parse.urlparse(handler.path).path
    if api.startswith("/community/api"):
        api = api[len("/community/api"):]
    mod = _module_of(api)
    if role != "super" and (mod in SUPER_ONLY_MODULES or mod not in perms):
        handler._err(403, "无权访问该模块：%s（%s）" % (
            mod, MODULE_LABELS.get(mod, mod)))
        return None
    return row[0], role, perms


def _auth(self, c, need_level=2):
    """身份确认（模块级权限已由 dispatch 的 _authed 统一校验）。

    返回 (token, level)；不通过回 401 并返回 None。保留 need_level 形参以兼容旧调用。
    """
    row = _who(c, self)
    if not row:
        self._err(401, "管理员令牌无效")
        return None
    return row[0], (row[1] or 2)


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
            "feedback": cnt("SELECT COUNT(*) FROM community_feedback WHERE status=0", ()),
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
                       "你的帖子已通过审核，快去看看吧", from_name="流萤社区官方", extra={"postId": pid})
                admin_log(c, adm[0], "audit_approve", "post", pid)
                try:
                    import ai_bot_core as _AIB
                    _AIB.on_post_reviewed(c, pid, True)
                except Exception:
                    pass
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
                       "你的帖子未通过审核：%s" % reason, from_name="流萤社区官方", extra={"postId": pid})
                admin_log(c, adm[0], "audit_reject", "post", pid, reason)
                try:
                    import ai_bot_core as _AIB
                    _AIB.on_post_reviewed(c, pid, False)
                except Exception:
                    pass
                c.commit()
                self._ok({"auditStatus": 2, "msg": "已拒绝"})
                return True
            self._err(400, "action 需为 approve/reject")
            return True
        if action == "pin":
            if method == "POST":
                c.execute("UPDATE community_posts SET sticky=1 WHERE id=?", (pid,))
                notify(c, d["user_id"], "community_audit", "置顶通知",
                       "你的帖子已被管理员置顶", from_name="流萤社区官方", extra={"postId": pid})
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
                       "你的帖子已被设为精华", from_name="流萤社区官方", extra={"postId": pid})
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
                       "你的内容已下架：%s" % reason, from_name="流萤社区官方", extra={"postId": pid})
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
        if d.get("status") == 1 and d.get("board_id"):
            bump_board_count(c, d["board_id"], -1)
        c.execute("UPDATE community_posts SET status=0 WHERE id=?", (pid,))
        if body.get("notifyAuthor"):
            notify(c, d["user_id"], "community_audit", "内容被删除",
                   "你的内容因违规已被管理员删除", from_name="流萤社区官方", extra={"postId": pid})
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
                       "你的评论被设为神评", from_name="流萤社区官方",
                       extra={"postId": d["post_id"], "commentId": cid})
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
            prow = c.execute("SELECT board_id, status FROM community_posts WHERE id=?",
                             (d["target_id"],)).fetchone()
            if prow and prow[1] == 1 and prow[0]:
                bump_board_count(c, prow[0], -1)
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
    if api == "/admin/boards" and method == "GET":
        rows = c.execute(
            "SELECT id,name,parent_id,icon,color,sort,active FROM community_boards"
            " ORDER BY sort ASC, name ASC").fetchall()
        try:
            cnt = {r[0]: r[1] for r in c.execute(
                "SELECT board_id, COUNT(*) FROM community_posts WHERE status=1").fetchall()}
        except Exception:
            cnt = {}
        nodes = [{"id": r[0], "name": r[1], "parentId": r[2] or "", "icon": r[3] or "",
                  "color": r[4] or "", "sort": r[5] or 0, "active": r[6] if r[6] is not None else 1,
                  "postCount": int(cnt.get(r[0], 0)), "children": []} for r in rows]
        idx = {n["id"]: n for n in nodes}
        roots = []
        for n in nodes:
            pid = n["parentId"]
            if pid and pid in idx:
                idx[pid]["children"].append(n)
            else:
                roots.append(n)
        roots.sort(key=lambda x: (x["sort"], x["name"]))
        c.commit()
        self._ok({"list": roots})
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


# ---------------- 管理端图片上传（Banner 等运营位素材） ----------------
def _handle_admin_upload(self, c, u, api, method):
    if api != "/admin/upload-image" or method != "POST":
        return False
    adm = _auth(self, c, 1)
    if not adm:
        return True
    fields, files = self._multipart(MAX_ADMIN_IMAGE * 3 + 8192)
    if files is None:
        self._err(400, "上传数据无效")
        return True
    fdata, fname = None, ""
    for k, (fn, data) in files.items():
        if data:
            fdata, fname = data, fn
            break
    if not fdata:
        self._err(400, "缺少图片文件")
        return True
    ext = os.path.splitext(fname)[1].lower()
    if ext not in ADMIN_IMG_EXT:
        ext = ".png"
    if not image_magic_ok(fdata[:32], ext):
        self._err(400, "图片格式校验失败")
        return True
    if len(fdata) > MAX_ADMIN_IMAGE:
        self._err(413, "图片过大（≤10MB）")
        return True
    name_out = "community_banner_%s%s" % (uuid.uuid4().hex[:12], ext)
    with open(os.path.join(FILES_DIR, name_out), "wb") as f:
        f.write(fdata)
    admin_log(c, adm[0], "banner_image_upload", "file", name_out)
    c.commit()
    self._ok({"name": name_out, "url": "/community/api/media/" + name_out})
    return True


def _banner_link_valid(link_type, link_id):
    """校验运营位跳转参数，避免后台填了半截值后客户端落到错误页面。"""
    t = (link_type or "").strip().lower()
    v = (link_id or "").strip()
    if t in ("", "none", "task"):
        return True
    if t == "url":
        return bool(re.match(r"^https?://", v, re.I))
    return bool(v)


def _handle_banner_settings_admin(self, c, u, api, method):
    """首页无 Banner 时的空态运营卡：标题、副标题、是否显示、点击目标。"""
    if api != "/admin/banner-settings":
        return False
    adm = _auth(self, c, 1)
    if not adm:
        return True
    row = c.execute(
        "SELECT * FROM community_banner_fallback WHERE id='default'").fetchone()
    if method == "GET":
        self._ok({"settings": row_dict(row) if row else {}})
        return True
    if method != "PUT":
        return False
    body = _body(self)
    enabled = 1 if body.get("enabled", 1) else 0
    title = (body.get("title") or "").strip()[:80]
    subtitle = (body.get("subtitle") or "").strip()[:160]
    link_type = (body.get("linkType") or "task").strip().lower()[:16]
    link_id = (body.get("linkId") or "").strip()[:300]
    if link_type not in ("none", "task", "url", "post", "topic", "user", "app"):
        self._err(400, "跳转类型不支持")
        return True
    if not _banner_link_valid(link_type, link_id):
        self._err(400, "跳转参数不完整：外链需以 http(s):// 开头，其它类型需填写目标")
        return True
    now = time.time()
    if row:
        c.execute(
            "UPDATE community_banner_fallback SET enabled=?, title=?, subtitle=?,"
            " link_type=?, link_id=?, updated=? WHERE id='default'",
            (enabled, title, subtitle, link_type, link_id, now))
    else:
        c.execute(
            "INSERT INTO community_banner_fallback"
            "(id,enabled,title,subtitle,link_type,link_id,updated)"
            " VALUES('default',?,?,?,?,?,?)",
            (enabled, title, subtitle, link_type, link_id, now))
    admin_log(c, adm[0], "banner_fallback_update", "banner_fallback", "default", title)
    c.commit()
    self._ok({"updated": True})
    return True


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
        link_type = (body.get("linkType") or "url").strip().lower()[:16]
        link_id = (body.get("linkId") or "").strip()[:300]
        if not _banner_link_valid(link_type, link_id):
            self._err(400, "跳转参数不完整：外链需以 http(s):// 开头，其它类型需填写目标")
            return True
        bid = uuid.uuid4().hex
        c.execute(
            "INSERT INTO community_banners(id,image,title,link_type,link_id,sort,active,start_at,end_at,created)"
            " VALUES(?,?,?,?,?,?,?,?,?,?)",
            (bid, image, (body.get("title") or "").strip()[:80], link_type,
             link_id, int(body.get("sort") or 0),
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
            link_type = body.get("linkType")
            link_id = body.get("linkId")
            if (link_type is not None or link_id is not None):
                row = c.execute("SELECT link_type,link_id FROM community_banners WHERE id=?",
                                (bid,)).fetchone()
                if not row:
                    self._err(404, "Banner 不存在")
                    return True
                lt = (link_type if link_type is not None else row[0]) or ""
                li = (link_id if link_id is not None else row[1]) or ""
                if not _banner_link_valid(lt, li):
                    self._err(400, "跳转参数不完整：外链需以 http(s):// 开头，其它类型需填写目标")
                    return True
            sets = []
            args = []
            for k, col in (("image", "image"), ("title", "title"),
                           ("linkType", "link_type"), ("linkId", "link_id"),
                           ("sort", "sort")):
                if k in body:
                    sets.append(col + "=?")
                    args.append(body[k] if k != "title" else str(body[k]).strip()[:80])
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
def _user_columns(c):
    return {r[1] for r in c.execute("PRAGMA table_info(users)").fetchall()}


def _admin_user_image_root():
    """头像/背景图必须落在音乐 files 目录，客户端按 uid 走 /music/avatar、/music/background。"""
    for root in (settings.music_files_dir, "/www/wwwroot/music/data/media/files"):
        if root and os.path.isdir(root):
            return os.path.realpath(root)
    return ""


def _admin_phone_mask(c, uid):
    mask = ""
    try:
        p = c.execute("SELECT phone_mask FROM community_invite_profiles WHERE user_id=?",
                      (uid,)).fetchone()
        if p:
            mask = p[0] or ""
        if not mask:
            a = c.execute("SELECT phone_mask FROM community_phone_accounts WHERE user_id=?",
                          (uid,)).fetchone()
            if a:
                mask = a[0] or ""
    except Exception:
        pass
    return mask


def _admin_user_payload(c, uid):
    """后台用户详情：资料字段 + 手机号掩码 + 会员/管理员状态。"""
    cols = _user_columns(c)
    fields = [
        ("id", "''"), ("account", "''"), ("name", "''"), ("avatar", "''"),
        ("created", "0"), ("banned", "0"), ("ban_reason", "''"),
        ("title", "''"), ("verified", "''"), ("verified_label", "''"),
        ("email", "''"), ("gender", "''"), ("age", "0"), ("city", "''"),
        ("background_image", "''"), ("signature", "''"),
    ]
    parts = []
    for name, default in fields:
        if name == "id":
            parts.append("id")
        elif name in cols:
            parts.append("COALESCE(%s,%s) AS %s" % (name, default, name))
        else:
            parts.append("%s AS %s" % (default, name))
    row = c.execute("SELECT %s FROM users WHERE id=?" % ", ".join(parts), (uid,)).fetchone()
    if not row:
        return None
    d = {name: row[i] for i, (name, _) in enumerate(fields)}
    now = time.time()
    exp = c.execute("SELECT exp, level FROM community_exp WHERE user_id=?", (uid,)).fetchone()
    mem = c.execute("SELECT level, expire FROM community_members WHERE user_id=?", (uid,)).fetchone()
    adm_row = c.execute(
        "SELECT level, COALESCE(name,''), COALESCE(role,'') FROM community_admins WHERE user_id=?",
        (uid,)).fetchone()
    admin_level = adm_row[0] if adm_row else 0
    admin_name = ""
    if adm_row:
        admin_name = adm_row[1] or ("社区超级管理员" if admin_level == 1 else "社区管理员")
    return {
        "id": d["id"], "account": d["account"] or "", "name": d["name"] or "",
        "avatar": d["avatar"] or "", "background": d["background_image"] or "",
        "created": d["created"] or 0, "banned": d["banned"] or 0,
        "banReason": d["ban_reason"] or "", "title": d["title"] or "",
        "verified": d["verified"] or "", "verifiedLabel": d["verified_label"] or "",
        "email": d["email"] or "", "emailVerified": bool(
            c.execute("SELECT email_verified FROM users WHERE id=?", (uid,)).fetchone()[0])
        if "email_verified" in cols else False,
        "gender": d["gender"] or "", "age": d["age"] or 0, "city": d["city"] or "",
        "signature": d["signature"] or "",
        "phoneMask": _admin_phone_mask(c, uid),
        "exp": exp[0] if exp else 0, "level": exp[1] if exp else 0,
        "member": (mem[0] or "") if (mem and mem[1] and mem[1] > now) else "",
        "adminLevel": admin_level, "adminName": admin_name,
    }


def _admin_phone_clear(c, uid):
    now = time.time()
    c.execute("DELETE FROM community_phone_accounts WHERE user_id=?", (uid,))
    c.execute("UPDATE community_invite_profiles SET phone_hash='', phone_mask='',"
              " phone_verified_at=0, updated=? WHERE user_id=?", (now, uid))
    c.execute("UPDATE community_invite_bindings SET phone_hash='', phone_mask=''"
              " WHERE invitee_id=?", (uid,))


def _admin_phone_bind(c, uid, phone):
    ph = invite_core.phone_hash(phone)
    mask = invite_core.mask_phone(phone)
    now = time.time()
    invite_core.ensure_profile(c, uid)
    c.execute("DELETE FROM community_phone_accounts WHERE user_id=? AND phone_hash<>?",
              (uid, ph))
    c.execute("UPDATE community_invite_profiles SET phone_hash=?, phone_mask=?,"
              " phone_verified_at=?, updated=? WHERE user_id=?",
              (ph, mask, now, now, uid))
    c.execute("INSERT INTO community_phone_accounts(phone_hash,phone_mask,user_id,created,verified_at)"
              " VALUES(?,?,?,?,?) ON CONFLICT(phone_hash) DO UPDATE SET"
              " user_id=excluded.user_id, phone_mask=excluded.phone_mask,"
              " verified_at=excluded.verified_at",
              (ph, mask, uid, now, now))
    c.execute("UPDATE community_invite_bindings SET phone_hash=?, phone_mask=?"
              " WHERE invitee_id=?", (ph, mask, uid))


def _admin_update_user(c, uid, body, allow_password=False):
    """保存后台可编辑的用户资料。返回 (changed_fields, 最新 payload)。

    QQ/手机号只存不可逆哈希和掩码；后台只能改绑，不能回显完整号码。
    """
    cols = _user_columns(c)
    if not c.execute("SELECT 1 FROM users WHERE id=?", (uid,)).fetchone():
        raise LookupError("用户不存在")
    body = dict(body or {})
    updates = {}
    changed = []
    if "name" in body:
        name = str(body.get("name") or "").strip()
        if not name:
            raise ValueError("昵称不能为空")
        if len(name) > 24:
            raise ValueError("昵称最多 24 个字")
        updates["name"] = name
        changed.append("昵称")
    if "signature" in body:
        sig = str(body.get("signature") or "").strip()
        if len(sig) > 100:
            raise ValueError("签名最多 100 个字")
        updates["signature"] = sig
        changed.append("签名")
    if "gender" in body:
        gender = str(body.get("gender") or "").strip()[:8]
        updates["gender"] = gender
        changed.append("性别")
    if "age" in body:
        try:
            age = int(body.get("age") or 0)
        except Exception:
            raise ValueError("年龄必须是数字")
        if age < 0 or age > 150:
            raise ValueError("年龄需在 0-150 之间")
        updates["age"] = age
        changed.append("年龄")
    if "city" in body:
        city = str(body.get("city") or "").strip()
        if len(city) > 32:
            raise ValueError("城市最多 32 个字")
        updates["city"] = city
        changed.append("城市")
    if "avatar" in body:
        avatar = str(body.get("avatar") or "").strip()
        if len(avatar) > 300 or "\n" in avatar:
            raise ValueError("头像值不合法")
        updates["avatar"] = avatar
        changed.append("头像")
    if "background" in body:
        bg = str(body.get("background") or "").strip()
        if len(bg) > 300 or "\n" in bg:
            raise ValueError("背景图值不合法")
        updates["background_image"] = bg
        changed.append("背景图")
    if "email" in body:
        email = str(body.get("email") or "").strip().lower()
        if email:
            if len(email) > 128 or not re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", email):
                raise ValueError("邮箱格式不正确")
            other = c.execute("SELECT id FROM users WHERE lower(email)=lower(?) AND id<>?",
                               (email, uid)).fetchone()
            if other:
                raise ValueError("该邮箱已被其他账号绑定")
        updates["email"] = email
        if "email_verified" in cols:
            updates["email_verified"] = 1 if email else 0
        changed.append("邮箱")
    password = str(body.get("password") or "").strip()
    if password:
        if not allow_password:
            raise PermissionError("只有超级管理员可以重置密码")
        if len(password) < 6 or len(password) > 64:
            raise ValueError("密码需为 6-64 个字符")
        from handlers.auth import _hash_password
        updates["password_hash"] = _hash_password(password)
        changed.append("密码")

    phone_given = "phone" in body
    phone = ""
    if phone_given:
        from handlers.auth import PHONE_RE
        phone = invite_core.normalize_phone(body.get("phone"))
        if phone:
            if not PHONE_RE.match(phone):
                raise ValueError("手机号需为 11 位中国大陆号码")
            ph = invite_core.phone_hash(phone)
            for table in ("community_phone_accounts", "community_invite_profiles"):
                other = c.execute("SELECT user_id FROM %s WHERE phone_hash=? AND user_id<>?" % table,
                                  (ph, uid)).fetchone()
                if other:
                    raise ValueError("该手机号已绑定其他账号")
            other = c.execute("SELECT invitee_id FROM community_invite_bindings"
                              " WHERE phone_hash=? AND invitee_id<>?", (ph, uid)).fetchone()
            if other:
                raise ValueError("该手机号已绑定其他账号")
            _admin_phone_bind(c, uid, phone)
        else:
            _admin_phone_clear(c, uid)
        changed.append("手机号")

    if updates:
        q = "UPDATE users SET " + ",".join(k + "=?" for k in updates) + " WHERE id=?"
        c.execute(q, tuple(updates.values()) + (uid,))
    c.commit()
    return changed, _admin_user_payload(c, uid)


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
            cols = _user_columns(c)
            search_cols = ["name", "account", "id"]
            if "email" in cols:
                search_cols.append("email")
            where = "(" + " OR ".join(x + " LIKE ?" for x in search_cols) + ")"
            like = "%" + keyword + "%"
            args = [like] * len(search_cols)
        total = c.execute("SELECT COUNT(*) FROM users WHERE %s" % where, args).fetchone()[0]
        ids = c.execute("SELECT id FROM users WHERE %s ORDER BY created DESC LIMIT ? OFFSET ?" % where,
                        args + [size, (page - 1) * size]).fetchall()
        out = []
        for r in ids:
            d = _admin_user_payload(c, r[0])
            if d:
                out.append(d)
        c.commit()
        self._ok({"list": out, "total": total, "page": page, "size": size})
        return True
    m = re.match(r"^/admin/users/([\w\-]+)/update$", api)
    if m and method == "POST":
        adm = _auth(self, c, 1)
        if not adm:
            return True
        uid = m.group(1)
        body = _body(self)
        who = _who(c, self)
        allow_password = bool(who and _role_of(who) == "super")
        try:
            changed, payload = _admin_update_user(c, uid, body, allow_password=allow_password)
        except PermissionError as e:
            self._err(403, str(e))
            return True
        except LookupError as e:
            self._err(404, str(e))
            return True
        except ValueError as e:
            self._err(400, str(e))
            return True
        admin_log(c, adm[0], "user_profile_update", "user", uid, ",".join(changed)[:200])
        c.commit()
        self._ok({"user": payload, "changed": changed})
        return True
    m = re.match(r"^/admin/users/([\w\-]+)/image$", api)
    if m and method == "POST":
        adm = _auth(self, c, 1)
        if not adm:
            return True
        uid = m.group(1)
        if not c.execute("SELECT 1 FROM users WHERE id=?", (uid,)).fetchone():
            self._err(404, "用户不存在")
            return True
        fields, files = self._multipart(MAX_ADMIN_IMAGE * 3 + 8192)
        if files is None:
            self._err(400, "上传数据无效")
            return True
        kind = str((fields or {}).get("kind") or "avatar").strip().lower()
        if kind not in ("avatar", "background"):
            self._err(400, "kind 需为 avatar/background")
            return True
        fdata, fname = None, ""
        for _, (fn, data) in (files or {}).items():
            if data:
                fdata, fname = data, fn
                break
        if not fdata:
            self._err(400, "缺少图片文件")
            return True
        ext = os.path.splitext(fname)[1].lower()
        if ext not in ADMIN_IMG_EXT:
            ext = ".jpg"
        if ext == ".jpeg":
            ext = ".jpg"
        if not image_magic_ok(fdata[:32], ext):
            self._err(400, "图片格式校验失败")
            return True
        if len(fdata) > MAX_ADMIN_IMAGE:
            self._err(413, "图片过大（≤10MB）")
            return True
        root = _admin_user_image_root()
        if not root:
            self._err(503, "头像/背景图存储目录不可用")
            return True
        out = uid + ("_avatar" if kind == "avatar" else "_background") + ext
        with open(os.path.join(root, out), "wb") as f:
            f.write(fdata)
        col = "avatar" if kind == "avatar" else "background_image"
        c.execute("UPDATE users SET %s=? WHERE id=?" % col, (out, uid))
        admin_log(c, adm[0], "user_%s_upload" % kind, "user", uid, out)
        c.commit()
        self._ok({"name": out, "kind": kind,
                  "url": "/community/api/music/%s/%s" % (kind, uid)})
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


def _gen_member_code(level):
    import random
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    body = "".join(random.choice(alphabet) for _ in range(12))
    tag = "SV" if level == "svip" else "VP"
    return "LY%s-%s-%s-%s" % (tag, body[:4], body[4:8], body[8:12])


def _handle_member_admin(self, c, u, api, method):
    """会员运营后台：套餐 / 兑换码 / 开通申请。"""
    if not api.startswith("/admin/member/"):
        return False
    adm = _auth(self, c, 1)
    if not adm:
        return True

    if api == "/admin/member/plans" and method == "GET":
        rows = c.execute("SELECT * FROM community_member_plans ORDER BY sort ASC").fetchall()
        c.commit()
        self._ok({"list": [row_dict(r) for r in rows]})
        return True
    if api == "/admin/member/plans" and method == "POST":
        body = _body(self)
        level = (body.get("level") or "").strip()
        if level not in ("member", "svip"):
            self._err(400, "level 需为 member/svip")
            return True
        days = max(1, min(3650, int(body.get("days") or 30)))
        price = max(0, int(body.get("price") or 0))
        name = (body.get("name") or "").strip()[:24] or ("%s 会员" % ("SVIP" if level == "svip" else "VIP"))
        pid = (body.get("id") or "").strip() or uuid.uuid4().hex
        dup = c.execute("SELECT id,name FROM community_member_plans WHERE level=? AND days=? AND id<>?",
                        (level, days, pid)).fetchone()
        if dup:
            self._err(400, "该档位已有 %d 天套餐（%s），请直接改那条" % (days, dup[1] or dup[0]))
            return True
        row = c.execute("SELECT 1 FROM community_member_plans WHERE id=?", (pid,)).fetchone()
        active = 1 if body.get("active", True) else 0
        if row:
            c.execute("UPDATE community_member_plans SET level=?,name=?,days=?,price=?,sort=?,active=? WHERE id=?",
                      (level, name, days, price, int(body.get("sort") or 0), active, pid))
        else:
            c.execute("INSERT INTO community_member_plans(id,level,name,days,price,benefits,sort,active,created)"
                      " VALUES(?,?,?,?,?,?,?,?,?)",
                      (pid, level, name, days, price, "[]", int(body.get("sort") or 0), active, time.time()))
        admin_log(c, adm[0], "plan_save", "member", pid, "%s %dd %d" % (level, days, price))
        c.commit()
        self._ok({"id": pid})
        return True

    if api == "/admin/member/codes" and method == "POST":
        body = _body(self)
        level = (body.get("level") or "").strip()
        if level not in ("member", "svip"):
            self._err(400, "level 需为 member/svip")
            return True
        days = max(1, min(3650, int(body.get("days") or 30)))
        count = max(1, min(200, int(body.get("count") or 1)))
        note = (body.get("note") or "").strip()[:60]
        batch = uuid.uuid4().hex[:8]
        created = []
        now = time.time()
        for _ in range(count):
            for _try in range(6):
                code = _gen_member_code(level)
                if not c.execute("SELECT 1 FROM community_member_codes WHERE code=?", (code,)).fetchone():
                    c.execute("INSERT INTO community_member_codes(code,level,days,batch,created,note)"
                              " VALUES(?,?,?,?,?,?)", (code, level, days, batch, now, note))
                    created.append(code)
                    break
        admin_log(c, adm[0], "code_gen", "member", batch, "%s %dd x%d" % (level, days, len(created)))
        c.commit()
        self._ok({"batch": batch, "codes": created, "count": len(created),
                  "level": level, "days": days})
        return True

    if api == "/admin/member/codes" and method == "GET":
        q = urllib.parse.parse_qs(u.query)
        state = (q.get("state") or [""])[0].strip()
        limit = max(1, min(500, int((q.get("limit") or ["100"])[0])))
        where = ""
        if state == "unused":
            where = " WHERE used_by=''"
        elif state == "used":
            where = " WHERE used_by<>''"
        rows = c.execute("SELECT code,level,days,batch,used_by,used_at,created,note"
                         " FROM community_member_codes%s ORDER BY created DESC LIMIT ?" % where,
                         (limit,)).fetchall()
        total = c.execute("SELECT COUNT(*) FROM community_member_codes").fetchone()[0]
        unused = c.execute("SELECT COUNT(*) FROM community_member_codes WHERE used_by=''").fetchone()[0]
        c.commit()
        self._ok({"list": [{"code": r[0], "level": r[1], "days": r[2], "batch": r[3],
                            "usedBy": r[4] or "", "usedAt": r[5] or 0,
                            "created": r[6], "note": r[7] or ""} for r in rows],
                  "total": total, "unused": unused})
        return True

    m = re.match(r"^/admin/member/codes/([A-Za-z0-9\-]+)$", api)
    if m and method == "DELETE":
        code = m.group(1).upper()
        row = c.execute("SELECT used_by FROM community_member_codes WHERE code=?", (code,)).fetchone()
        if not row:
            self._err(404, "兑换码不存在")
            return True
        if row[0]:
            self._err(400, "已使用的兑换码不能删除")
            return True
        c.execute("DELETE FROM community_member_codes WHERE code=?", (code,))
        admin_log(c, adm[0], "code_del", "member", code)
        c.commit()
        self._ok({"deleted": True})
        return True

    if api == "/admin/member/orders" and method == "GET":
        q = urllib.parse.parse_qs(u.query)
        status = int((q.get("status") or ["0"])[0])
        if status == 0:
            rows = c.execute("SELECT o.id,o.user_id,o.level,o.days,o.price,o.contact,o.note,o.created,u.name,u.account,o.proof,o.channel"
                             " FROM community_member_orders o LEFT JOIN users u ON u.id=o.user_id"
                             " WHERE o.status=0 AND o.channel='apply' ORDER BY o.created DESC LIMIT 100").fetchall()
        else:
            rows = c.execute("SELECT o.id,o.user_id,o.level,o.days,o.price,o.contact,o.note,o.created,u.name,u.account,o.proof,o.channel"
                             " FROM community_member_orders o LEFT JOIN users u ON u.id=o.user_id"
                             " WHERE o.status=? ORDER BY o.created DESC LIMIT 100", (status,)).fetchall()
        c.commit()
        self._ok({"list": [{"id": r[0], "userId": r[1], "level": r[2], "days": r[3], "price": r[4],
                            "contact": r[5] or "", "note": r[6] or "", "created": r[7],
                            "name": r[8] or "", "account": r[9] or "", "proof": r[10] or "", "channel": r[11] or ""} for r in rows]})
        return True

    m = re.match(r"^/admin/member/orders/([\w\-]+)/(approve|reject)$", api)
    if m and method == "POST":
        oid, action = m.group(1), m.group(2)
        row = c.execute("SELECT user_id, level, days, status, price FROM community_member_orders WHERE id=?",
                        (oid,)).fetchone()
        if not row:
            self._err(404, "记录不存在")
            return True
        if row[3] != 0:
            self._err(400, "该申请已处理")
            return True
        uid, level, days = row[0], row[1], int(row[2])
        if action == "reject":
            c.execute("UPDATE community_member_orders SET status=2, updated=? WHERE id=?", (time.time(), oid))
            admin_log(c, adm[0], "member_reject", "user", uid, oid)
            c.commit()
            self._ok({"rejected": True})
            return True
        now = time.time()
        cur = c.execute("SELECT level, expire FROM community_members WHERE user_id=?", (uid,)).fetchone()
        base = max(now, (cur[1] or 0) if cur else 0)
        expire = base + days * 86400
        if cur:
            c.execute("UPDATE community_members SET level=?, expire=?, updated=? WHERE user_id=?",
                      (level, expire, now, uid))
        else:
            c.execute("INSERT INTO community_members(user_id,level,expire,created,updated)"
                      " VALUES(?,?,?,?,?)", (uid, level, expire, now, now))
        c.execute("UPDATE community_member_orders SET status=1, updated=? WHERE id=?", (now, oid))
        invite_core.credit_membership(c, uid, oid, int(row[4] or 0))
        admin_log(c, adm[0], "member_approve", "user", uid, "%s %dd" % (level, days))
        c.commit()
        self._ok({"approved": True, "expire": expire})
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
        receiver = (body.get("userId") or "").strip()
        raw_rich = body.get("rich")
        if raw_rich:
            try:
                rich, plain = sanitize_official_rich(raw_rich)
            except ValueError as exc:
                self._err(400, str(exc) or "富文本格式错误")
                return True
            content = json.dumps(rich, ensure_ascii=False, separators=(",", ":"))
            official_msg(c, receiver, content, content_type="rich", plain_text=plain)
            admin_log(c, adm[0], "official_send", "user", receiver, plain[:50])
            c.commit()
            self._ok({"sent": True, "contentType": "rich"})
            return True
        content = (body.get("content") or "").strip()[:1000]
        if not content:
            self._err(400, "内容必填")
            return True
        official_msg(c, receiver, content)
        admin_log(c, adm[0], "official_send", "user", receiver, content[:50])
        c.commit()
        self._ok({"sent": True, "contentType": "text"})
        return True
    if api == "/admin/official":
        rows = c.execute("SELECT * FROM community_official_messages ORDER BY created DESC LIMIT 100").fetchall()
        c.commit()
        out = []
        for r in rows:
            ctype = (r[5] or "text") if len(r) > 5 else "text"
            item = {"id": r[0], "content": r[1], "senderName": r[2],
                    "userId": r[3], "created": r[4], "contentType": ctype,
                    "plainText": (r[6] or "") if len(r) > 6 else ""}
            if ctype == "rich":
                try:
                    item["rich"] = json.loads(r[1])
                except (TypeError, ValueError):
                    item["plainText"] = item["plainText"] or r[1][:1000]
            out.append(item)
        self._ok({"list": out})
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
        ml = (body.get("memberLevel") or "").strip()
        if ml not in ("", "member", "svip"):
            self._err(400, "memberLevel 需为空 / member / svip")
            return True
        c.execute("INSERT INTO community_frames(id,name,image,image_dynamic,sort,member_level,active,created)"
                  " VALUES(?,?,?,?,?,?,1,?)",
                  (fid, name, image, image_dynamic, int(body.get("sort") or 0), ml, time.time()))
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
                           ("imageDynamic", "image_dynamic"), ("sort", "sort"),
                           ("memberLevel", "member_level")):
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
    # 管理员管理：模块级已限定 admins（仅超管）
    if api == "/admin/admins" and method == "GET":
        adm = _auth(self, c)
        if not adm:
            return True
        rows = c.execute(
            "SELECT a.token, a.user_id, a.level, a.name, a.created, COALESCE(u.name,''),"
            " COALESCE(u.avatar,''), COALESCE(a.role,''), COALESCE(a.perms,'')"
            " FROM community_admins a LEFT JOIN users u ON u.id=a.user_id"
            " ORDER BY CASE COALESCE(NULLIF(a.role,''),CASE WHEN a.level=1 THEN 'super' ELSE 'auditor' END)"
            "  WHEN 'super' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END, a.created ASC").fetchall()
        c.commit()
        out = []
        for r in rows:
            role = (r[7] or "").strip() or ("super" if (r[2] or 2) == 1 else "auditor")
            perms = [x for x in (r[8] or "").split(",") if x] if role != "super" else list(ADMIN_MODULES) + list(SUPER_ONLY_MODULES)
            out.append({
                "token": r[0][:12] + "…",
                "userId": r[1] or "",
                "userName": r[5] or "",
                "avatar": r[6] or "",
                "name": r[5] or r[3] or "",
                "role": role,
                "level": 1 if role == "super" else 2,
                "perms": perms,
                "created": r[4],
                "isSuper": role == "super",
            })
        self._ok({"list": out, "modules": list(ADMIN_MODULES),
                  "labels": MODULE_LABELS})
        return True

    if api in ("/admin/admins/grant", "/admin/admins/update") and method == "POST":
        adm = _auth(self, c)
        if not adm:
            return True
        body = _body(self)
        uid = (body.get("userId") or "").strip()
        if not uid or not c.execute("SELECT 1 FROM users WHERE id=?", (uid,)).fetchone():
            self._err(404, "用户不存在")
            return True
        role = (body.get("role") or "auditor").strip()
        if role not in ("admin", "auditor"):
            self._err(400, "角色只能是 admin（管理员）或 auditor（审核员）")
            return True
        perms_raw = body.get("perms")
        if perms_raw is None:
            # 未显式传 perms 时按角色给默认职责：审核员默认可审核内容/评论/反馈。
            perms = (["content", "comments", "feedback"] if role == "auditor"
                     else list(ADMIN_MODULES))
        elif isinstance(perms_raw, list):
            perms = [x for x in perms_raw if x in ADMIN_MODULES]
        else:
            perms = []
        existing = c.execute(
            "SELECT COALESCE(role,''), level FROM community_admins WHERE user_id=?", (uid,)).fetchone()
        if existing and ((existing[0] or "") == "super" or ((not existing[0]) and (existing[1] or 2) == 1)):
            self._err(403, "超级管理员不可被修改")
            return True
        name = (body.get("name") or "社区管理员").strip()[:20]
        if existing:
            c.execute("UPDATE community_admins SET role=?, perms=?, name=?, level=2 WHERE user_id=?",
                      (role, ",".join(perms), name, uid))
            tok = c.execute("SELECT token FROM community_admins WHERE user_id=?", (uid,)).fetchone()[0]
        else:
            tok = secrets.token_urlsafe(24)
            c.execute("INSERT INTO community_admins(token,user_id,level,name,created,role,perms)"
                      " VALUES(?,?,?,?,?,?,?)",
                      (tok, uid, 2, name, time.time(), role, ",".join(perms)))
        admin_log(c, adm[0], "grant_admin" if not existing else "update_admin", "user", uid,
                  "%s:%s" % (role, ",".join(perms)))
        c.commit()
        self._ok({"userId": uid, "level": 2, "role": role, "perms": perms, "token": tok,
                  "msg": "已更新" if existing else "已新增"})
        return True

    if api == "/admin/admins/revoke" and method == "POST":
        adm = _auth(self, c)
        if not adm:
            return True
        body = _body(self)
        uid = (body.get("userId") or "").strip()
        row = c.execute("SELECT COALESCE(role,''), level FROM community_admins WHERE user_id=?", (uid,)).fetchone()
        if not row:
            self._err(404, "该用户不是管理员")
            return True
        if (row[0] or "") == "super" or ((not row[0]) and (row[1] or 2) == 1):
            self._err(403, "超级管理员不可撤销")
            return True
        c.execute("DELETE FROM community_admins WHERE user_id=? AND COALESCE(role,'')!='super'", (uid,))
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
    # 审计日志接口不得回传 admin_token（哪怕已哈希）；只给排障所需字段。
    rows = c.execute(
        "SELECT id, action, target_type, target_id, detail, created"
        " FROM community_admin_logs ORDER BY created DESC LIMIT 100").fetchall()
    c.commit()
    out = []
    for r in rows:
        out.append({
            "id": r[0], "action": r[1], "targetType": r[2],
            "targetId": r[3], "detail": r[4], "created": r[5],
        })
    self._ok({"list": out})
    return True


def _resolve_user(c, raw):
    """把「uid / 账号 / 昵称」统一解析成 users 表里的规范 uid。"""
    raw = (raw or "").strip()
    if not raw:
        return None
    for sql in ("SELECT id,name,account FROM users WHERE id=? LIMIT 1",
                "SELECT id,name,account FROM users WHERE account=? LIMIT 1",
                "SELECT id,name,account FROM users WHERE name=? LIMIT 1"):
        try:
            row = c.execute(sql, (raw,)).fetchone()
        except Exception:
            row = None
        if row:
            return row
    return None


def _af_db_file(uid):
    """只读地拼出 work.db 路径，不创建目录。"""
    base = os.environ.get("AF_BASE", "/www/wwwroot/Yosar-community/data/af")
    return os.path.join(base, uid, "work.db")


def _handle_epay_admin(self, c, u, api, method):
    """易支付配置：查看 / 保存 / 连通性检测（仅超管）。"""
    if api == "/admin/epay/config" and method == "GET":
        cfg = epay.settings()
        key = cfg.get("key") or ""
        mask = (key[:4] + "****" + key[-4:]) if len(key) > 8 else ("已配置" if key else "")
        source = "社区后台" if os.path.exists(epay.COMMUNITY_CFG) else "音乐项目"
        self._ok({
            "enabled": bool(cfg.get("enabled")),
            "pid": cfg.get("pid") or "",
            "gateway": cfg.get("gateway") or "",
            "keySet": bool(key),
            "keyMask": mask,
            "source": source,
            "notifyUrl": settings.public_base + "/member/epay/notify",
            "returnUrl": settings.public_base + "/member/epay/return",
        })
        return True
    if api == "/admin/epay/config" and method == "POST":
        body = self._json_body() or {}
        try:
            cfg = epay.save({
                "enabled": body.get("enabled"),
                "pid": body.get("pid"),
                "key": body.get("key"),
                "gateway": body.get("gateway"),
            })
        except epay.EpayError as e:
            self._err(400, str(e))
            return True
        adm = admin_required(c, self)
        if adm:
            admin_log(c, adm[0], "epay_config", "system", "", "更新易支付配置")
        c.commit()
        key = cfg.get("key") or ""
        mask = (key[:4] + "****" + key[-4:]) if len(key) > 8 else ("已配置" if key else "")
        self._ok({"saved": True, "enabled": cfg.get("enabled"), "pid": cfg.get("pid"),
                  "gateway": cfg.get("gateway"), "keySet": bool(key), "keyMask": mask})
        return True
    if api == "/admin/epay/test" and method == "POST":
        self._ok(epay.probe())
        return True
    return False


def _handle_af_admin(self, c, u, api, method):
    """AI 工坊运营：用户额度/余额、手工充值赠送、兑换码、消耗流水。"""
    if not (api or "").startswith("/admin/af"):
        return False
    adm = _auth(self, c, 3)
    if not adm:
        return True
    if api == "/admin/af/overview" and method == "GET":
        import glob as _glob
        import sqlite3 as _sq
        base = os.environ.get("AF_BASE", "/www/wwwroot/Yosar-community/data/af")
        now = time.time()
        day = now - 86400
        users, convs, msgs, tin, tout, hit, miss = 0, 0, 0, 0, 0, 0, 0
        msg_today, img_cnt = 0, 0
        tops = []
        for d in sorted(_glob.glob(os.path.join(base, "*"))):
            db = os.path.join(d, "work.db")
            if not os.path.isfile(db):
                continue
            uid = os.path.basename(d)
            try:
                if not c.execute("SELECT 1 FROM users WHERE id=?", (uid,)).fetchone():
                    continue
            except Exception:
                pass
            try:
                con = _sq.connect(db)
                con.row_factory = _sq.Row
                cv = con.execute("SELECT COUNT(*) FROM conversations").fetchone()[0]
                mg = con.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
                agg = con.execute(
                    "SELECT COALESCE(SUM(tokens_in),0) a, COALESCE(SUM(tokens_out),0) b,"
                    " COALESCE(SUM(cache_hit),0) h, COALESCE(SUM(cache_miss),0) m"
                    " FROM messages").fetchone()
                td = con.execute(
                    "SELECT COUNT(*) FROM messages WHERE created>?", (day,)).fetchone()[0]
                try:
                    im = con.execute(
                        "SELECT COUNT(*) FROM usage WHERE kind LIKE '%image%'").fetchone()[0]
                except Exception:
                    im = 0
                # usage 表可能不记图片；以实际产出的图片文件兜底，避免「有图但显示 0」
                if im == 0:
                    try:
                        gdir = os.path.join(
                            os.environ.get("FILES_ROOT", "/www/wwwroot/Yosar-community/files"),
                            "af", uid, "generated")
                        if os.path.isdir(gdir):
                            im = len([f for f in os.listdir(gdir) if f.lower().endswith((".png", ".jpg", ".jpeg", ".webp"))])
                    except Exception:
                        im = 0
                con.close()
                if cv == 0 and mg == 0:
                    continue
                users += 1
                convs += cv
                msgs += mg
                tin += int(agg["a"] or 0)
                tout += int(agg["b"] or 0)
                hit += int(agg["h"] or 0)
                miss += int(agg["m"] or 0)
                msg_today += td
                img_cnt += im
                tops.append({"uid": uid, "convs": cv, "msgs": mg,
                             "tokens": int(agg["a"] or 0) + int(agg["b"] or 0),
                             "today": td})
            except Exception:
                continue
        tops.sort(key=lambda x: x["tokens"], reverse=True)
        for t in tops[:12]:
            try:
                ur = c.execute("SELECT name,account FROM users WHERE id=?",
                               (t["uid"],)).fetchone()
                t["name"] = (ur[0] if ur else "") or ""
                t["account"] = (ur[1] if ur else "") or ""
            except Exception:
                t["name"] = ""
                t["account"] = ""
        total_cache = hit + miss
        self._ok({
            "users": users, "convs": convs, "msgs": msgs,
            "tokens_in": tin, "tokens_out": tout,
            "cache_hit": hit, "cache_miss": miss,
            "cache_rate": round(hit * 100.0 / total_cache, 1) if total_cache else 0,
            "msg_today": msg_today, "images": img_cnt,
            "top": tops[:10],
        })
        return True

    if api == "/admin/af/convs" and method == "GET":
        import sqlite3 as _sq
        uid = (self._query("uid") if hasattr(self, "_query") else "") or ""
        if not uid:
            qs = (self.path or "").split("?")
            if len(qs) > 1:
                for kv in qs[1].split("&"):
                    if kv.startswith("uid="):
                        uid = __import__("urllib.parse").parse.unquote(kv[4:])
        uid = uid.strip()
        if not uid:
            self._err(400, "缺少 uid")
            return True
        base = os.environ.get("AF_BASE", "/www/wwwroot/Yosar-community/data/af")
        db = os.path.join(base, uid, "work.db")
        if not os.path.isfile(db):
            self._ok({"list": []})
            return True
        con = _sq.connect(db)
        con.row_factory = _sq.Row
        rows = con.execute(
            "SELECT id,title,model,effort,pinned,created,updated FROM conversations"
            " ORDER BY updated DESC LIMIT 200").fetchall()
        out = []
        for r in rows:
            cnt = con.execute("SELECT COUNT(*) FROM messages WHERE conv_id=?", (r["id"],)).fetchone()[0]
            out.append({"id": r["id"], "title": r["title"] or "", "model": r["model"] or "",
                        "effort": r["effort"] or "", "pinned": int(r["pinned"] or 0),
                        "msgs": cnt, "created": r["created"] or 0, "updated": r["updated"] or 0})
        con.close()
        self._ok({"list": out})
        return True

    if api == "/admin/af/conv" and method == "GET":
        import sqlite3 as _sq
        uid, cid = "", ""
        qs = (self.path or "").split("?")
        if len(qs) > 1:
            for kv in qs[1].split("&"):
                if kv.startswith("uid="):
                    uid = kv[4:]
                elif kv.startswith("id="):
                    cid = kv[3:]
        uid = __import__("urllib.parse").parse.unquote(uid).strip()
        cid = __import__("urllib.parse").parse.unquote(cid).strip()
        if not uid or not cid:
            self._err(400, "缺少 uid 或 id")
            return True
        base = os.environ.get("AF_BASE", "/www/wwwroot/Yosar-community/data/af")
        db = os.path.join(base, uid, "work.db")
        if not os.path.isfile(db):
            self._ok({"list": []})
            return True
        con = _sq.connect(db)
        con.row_factory = _sq.Row
        rows = con.execute(
            "SELECT id,role,content,reasoning,tokens_in,tokens_out,created FROM messages"
            " WHERE conv_id=? ORDER BY created ASC LIMIT 400", (cid,)).fetchall()
        out = []
        for r in rows:
            out.append({
                "id": r["id"], "role": r["role"] or "",
                "content": (r["content"] or "")[:600],
                "reasoning": (r["reasoning"] or "")[:300],
                "tokens_in": int(r["tokens_in"] or 0), "tokens_out": int(r["tokens_out"] or 0),
                "created": r["created"] or 0,
            })
        con.close()
        self._ok({"list": out})
        return True

    if api == "/admin/af/settings" and method == "GET":
        import af_core as _AF
        cfg = _AF.deepseek_cfg()
        img_cfg = {}
        try:
            import af_core as _AFK
            with open(_AFK.MUSIC_AI_CFG, encoding="utf-8") as f:
                img_cfg = (json.loads(f.read() or "{}").get("image") or {})
        except Exception:
            img_cfg = {}
        sb = {}
        try:
            import af_sandbox as _SB
            sb = _SB.status()
        except Exception as e:
            sb = {"ok": False, "error": str(e)[:80]}
        self._ok({
            "model": cfg.get("model") or "", "base": cfg.get("base") or "",
            "key_set": bool(cfg.get("key")), "effort": cfg.get("effort") or {},
            "image": {
                "base": img_cfg.get("base") or os.environ.get("AF_IMAGE_BASE", ""),
                "model": img_cfg.get("model") or os.environ.get("AF_IMAGE_MODEL", "") or "gpt-image-1",
                "key_set": bool(img_cfg.get("key") or os.environ.get("AF_IMAGE_KEY")),
            },
            "sandbox": sb,
            "image_tool": True,
        })
        return True

    if api == "/admin/af/settings" and method == "POST":
        import af_core as _AF
        b = _body(self)
        path = _AF.MUSIC_AI_CFG
        try:
            with open(path, encoding="utf-8") as f:
                allcfg = json.loads(f.read() or "{}")
        except Exception:
            allcfg = {}
        chat = allcfg.get("chat") or {}
        if b.get("model"):
            chat["model"] = str(b["model"]).strip()
        if isinstance(b.get("effort"), dict):
            eff = chat.get("effort") or {}
            for k in ("fast", "think", "deep"):
                if b["effort"].get(k):
                    eff[k] = str(b["effort"][k]).strip()
            chat["effort"] = eff
        allcfg["chat"] = chat
        if isinstance(b.get("image"), dict):
            im = allcfg.get("image") or {}
            if "base" in b["image"]:
                im["base"] = str(b["image"]["base"]).strip()
            if "model" in b["image"]:
                im["model"] = str(b["image"]["model"]).strip()
            if b["image"].get("key"):
                im["key"] = str(b["image"]["key"]).strip()
            if b["image"].get("clear_key"):
                im.pop("key", None)
            allcfg["image"] = im
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(json.dumps(allcfg, ensure_ascii=False, indent=2))
        except Exception as e:
            self._err(500, "写入失败: %s" % str(e)[:120])
            return True
        self._ok({"ok": True})
        return True

    if api == "/admin/af/persona" and method == "GET":
        try:
            import handlers.af as _H
            txt = getattr(_H, "SYSTEM_RULES", "") or ""
        except Exception as e:
            txt = ""
        self._ok({"text": txt, "len": len(txt)})
        return True

    if api == "/admin/af/users" and method == "GET":
        rows = c.execute(
            "SELECT user_id,plan,quota_month,quota_used,status,storage_quota,"
            "balance,gift_left,last_active FROM af_tenants ORDER BY last_active DESC LIMIT 300").fetchall()
        out = []
        for r in rows:
            ur = c.execute("SELECT name,account FROM users WHERE id=?", (r[0],)).fetchone()
            out.append({"uid": r[0], "name": (ur[0] if ur else ""), "account": (ur[1] if ur else ""),
                        "orphan": (ur is None),
                        "plan": r[1], "gift_left": int(r[7] or 0), "balance": int(r[6] or 0),
                        "balance_yuan": round(int(r[6] or 0) / 100.0, 2),
                        "last_active": r[8] or 0})
        self._ok({"list": out})
        return True
    if api == "/admin/af/resolve" and method == "GET":
        qs = (self.path or "").split("?")
        raw = ""
        if len(qs) > 1:
            for kv in qs[1].split("&"):
                if kv.startswith("q="):
                    raw = __import__("urllib.parse").parse.unquote(kv[2:])
        urow = _resolve_user(c, raw.strip())
        if not urow:
            self._ok({"found": False, "q": raw})
            return True
        has = c.execute("SELECT plan,gift_left,balance FROM af_tenants WHERE user_id=?",
                        (urow[0],)).fetchone()
        self._ok({"found": True, "uid": urow[0], "name": urow[1] or "",
                  "account": urow[2] or "",
                  "tenant": bool(has),
                  "plan": (has[0] if has else ""),
                  "gift_left": (int(has[1] or 0) if has else 0),
                  "balance": (int(has[2] or 0) if has else 0)})
        return True

    if api == "/admin/af/cleanup" and method == "POST":
        b = _body(self)
        raw = (b.get("uid") or "").strip()
        if not raw:
            self._err(400, "缺少 uid")
            return True
        if _resolve_user(c, raw):
            self._err(400, "这个 uid 对应真实用户，不能清理")
            return True
        existed = c.execute("SELECT 1 FROM af_tenants WHERE user_id=?", (raw,)).fetchone()
        if not existed:
            self._err(404, "没有这条记录")
            return True
        dbp = _af_db_file(raw)
        keep = False
        try:
            import sqlite3 as _sq4
            if os.path.isfile(dbp):
                con4 = _sq4.connect(dbp)
                cv = con4.execute("SELECT COUNT(*) FROM conversations").fetchone()[0]
                mg = con4.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
                con4.close()
                keep = bool(cv or mg)
        except Exception:
            keep = True
        if keep:
            self._err(409, "这条记录下还有会话数据，没敢删")
            return True
        c.execute("DELETE FROM af_tenants WHERE user_id=?", (raw,))
        c.commit()
        try:
            import shutil as _sh
            d = os.path.dirname(dbp)
            if os.path.isdir(d):
                _sh.rmtree(d, ignore_errors=True)
        except Exception:
            pass
        self._ok({"ok": True, "removed": raw})
        return True

    if api == "/admin/af/grant" and method == "POST":
        b = _body(self)
        raw = (b.get("uid") or "").strip()
        if not raw:
            self._err(400, "填写用户 uid、账号或昵称")
            return True
        yuan = float(b.get("yuan") or 0)
        gift = int(b.get("gift") or 0)
        if yuan <= 0 and gift <= 0:
            self._err(400, "充值或赠送至少给一项")
            return True
        urow = _resolve_user(c, raw)
        if not urow:
            self._err(404, "找不到这个用户：uid / 账号 / 昵称都没匹配上")
            return True
        uid = urow[0]
        if raw != uid:
            # 历史数据里可能把账号当成 uid 建过租户，一并合并过来
            try:
                old = c.execute("SELECT gift_left,balance FROM af_tenants WHERE user_id=?",
                                (raw,)).fetchone()
                if old:
                    c.execute("UPDATE af_tenants SET gift_left=gift_left+?, balance=balance+? WHERE user_id=?",
                              (int(old[0] or 0), int(old[1] or 0), uid))
                    c.execute("DELETE FROM af_tenants WHERE user_id=?", (raw,))
                    c.commit()
            except Exception:
                pass
        r = c.execute("SELECT 1 FROM af_tenants WHERE user_id=?", (uid,)).fetchone()
        if not r:
            if not b.get("create"):
                self._err(409, "该用户还没用过工坊，确认要为他开通并赠送吗")
                return True
            try:
                import af_core as _AFT
                _AFT.tenant(c, uid)
            except Exception as e:
                self._err(500, "开通失败: %s" % str(e)[:100])
                return True
        fen = int(round(yuan * 100))
        try:
            c.execute("ALTER TABLE af_tenants ADD COLUMN balance INTEGER DEFAULT 0")
        except Exception:
            pass
        try:
            c.execute("ALTER TABLE af_tenants ADD COLUMN gift_left INTEGER DEFAULT 0")
        except Exception:
            pass
        if fen > 0:
            c.execute("UPDATE af_tenants SET balance=balance+? WHERE user_id=?", (fen, uid))
        if gift > 0:
            c.execute("UPDATE af_tenants SET gift_left=gift_left+? WHERE user_id=?", (gift, uid))
        c.commit()
        try:
            import sys as _sys
            _sys.path.insert(0, "/www/wwwroot/Yosar-community")
            import af_core as _AF
            u2 = _AF.user_db(uid)
            u2.execute("INSERT INTO bills(id,uid,kind,model,fen,gift,note,created) VALUES(?,?,?,?,?,?,?,?)",
                       (_AF.uuid_hex(), uid, "admin_grant", "", fen, gift,
                        "后台调整 %.2f 元 / %d token" % (yuan, gift), __import__("time").time()))
            u2.commit()
        except Exception:
            pass
        self._ok({"ok": True, "yuan": yuan, "gift": gift,
                  "uid": uid, "name": (urow[1] or ""), "account": (urow[2] or "")})
        return True
    if api == "/admin/af/bills" and method == "GET":
        uid = (urllib.parse.parse_qs(u.query).get("uid") or [""])[0]
        if not uid:
            self._err(400, "缺少 uid")
            return True
        urow = _resolve_user(c, uid)
        if urow:
            uid = urow[0]
        dbp = _af_db_file(uid)
        if not os.path.isfile(dbp):
            self._ok({"list": []})
            return True
        try:
            import sqlite3 as _sq3
            u2 = _sq3.connect(dbp)
            u2.row_factory = _sq3.Row
            rows = u2.execute("SELECT kind,model,tokens_in,tokens_out,fen,gift,note,created FROM bills "
                              "ORDER BY created DESC LIMIT 200").fetchall()
            u2.close()
            self._ok({"list": [{"kind": r[0], "model": r[1], "tokens_in": r[2], "tokens_out": r[3],
                                "fen": r[4], "gift": r[5], "note": r[6], "created": r[7]} for r in rows]})
        except Exception as e:
            self._err(500, str(e)[:120])
        return True
    if api == "/admin/af/codes":
        if method == "GET":
            rows = c.execute("SELECT code,amount,used_by,used_at,created FROM af_redeem ORDER BY created DESC LIMIT 100").fetchall()
            self._ok({"list": [{"code": r[0], "amount": r[1], "used_by": r[2], "used_at": r[3], "created": r[4]} for r in rows]})
            return True
        if method == "POST":
            b = _body(self)
            amount = int(b.get("amount") or 0)
            n = max(1, min(int(b.get("count") or 1), 50))
            if amount <= 0:
                self._err(400, "token 数必须大于 0")
                return True
            made = []
            for _i in range(n):
                code = "AF" + __import__("uuid").uuid4().hex[:10].upper()
                c.execute("INSERT INTO af_redeem(code,amount,created) VALUES(?,?,?)",
                          (code, amount, __import__("time").time()))
                made.append({"code": code, "amount": amount})
            c.commit()
            self._ok({"list": made})
            return True
    return False


def _handle_feedback_admin(self, c, u, api, method):
    """反馈处理：GET /admin/feedback?status=0 列表；PUT /admin/feedback/{id} 状态/回复。"""
    if api == "/admin/feedback":
        adm = _auth(self, c, 2)
        if not adm:
            return True
        query = urllib.parse.parse_qs(u.query)
        status = int((query.get("status") or ["0"])[0] or 0)
        rows = c.execute(
            "SELECT * FROM community_feedback WHERE status=? ORDER BY created DESC LIMIT 100",
            (status,)).fetchall()
        out = []
        for r in rows:
            d = row_dict(r)
            urow = c.execute("SELECT name, account FROM users WHERE id=?",
                             (d["user_id"],)).fetchone()
            out.append({"id": d["id"], "type": d["type"], "content": d["content"],
                        "contact": d.get("contact", ""), "status": d.get("status", 0),
                        "reply": d.get("reply", ""), "created": d.get("created", 0),
                        "user": {"name": urow[0] if urow else "",
                                 "account": urow[1] if urow else ""}})
        c.commit()
        self._ok({"list": out})
        return True
    m = re.match(r"^/admin/feedback/([\w\-]+)$", api)
    if m and method == "PUT":
        adm = _auth(self, c, 2)
        if not adm:
            return True
        fid = m.group(1)
        row = c.execute("SELECT 1 FROM community_feedback WHERE id=?", (fid,)).fetchone()
        if not row:
            self._err(404, "反馈不存在")
            return True
        body = _body(self)
        sets = []
        args = []
        if "status" in body:
            sets.append("status=?")
            args.append(int(body.get("status") or 0))
        if "reply" in body:
            sets.append("reply=?")
            args.append((body.get("reply") or "").strip()[:500])
        if not sets:
            sets.append("status=?")
            args.append(0)
        sets.append("updated=?")
        args.append(time.time())
        c.execute("UPDATE community_feedback SET %s WHERE id=?" % ",".join(sets), args + [fid])
        admin_log(c, adm[0], "feedback_handle", "feedback", fid,
                  (body.get("reply") or "")[:40])
        c.commit()
        self._ok({"updated": True})
        return True
    return False


def dispatch(self, c, u, api, method):
    # 只管后台接口：非 /admin 前缀直接交回路由表，避免鉴权误伤 App 接口
    if not api.startswith("/admin"):
        return False
    # 当前身份（含角色与模块权限）：前端据此渲染菜单
    if api == "/admin/me":
        row = _who(c, self)
        if not row:
            self._err(401, "管理员令牌无效")
            return True
        role = _role_of(row)
        perms = _perms_of(row)
        if role == "super":
            perms = list(ADMIN_MODULES) + list(SUPER_ONLY_MODULES)
        self._ok({"role": role, "perms": perms, "name": row[4] or "管理员",
                  "modules": list(ADMIN_MODULES), "labels": MODULE_LABELS})
        return True

    # 统一模块级鉴权（超管全通；其余按勾选的模块放行）
    if not _authed(c, self):
        return True

    handlers = [_handle_stats, _handle_admin_posts, _handle_admin_comments,
                _handle_reports, _crud_boards, _handle_topics_admin,
                _handle_admin_upload,
                _handle_banner_settings_admin, _handle_banners_admin,
                _handle_activities_admin,
                _handle_sensitive_admin, _handle_users_admin,
                _handle_members_admin, _handle_member_admin, _handle_official_admin,
                _handle_frames_admin, _handle_emojis_admin,
                _handle_level_config, _handle_admins_admin,
                _handle_token_rotate, _handle_hotwords, _handle_logs,
                _handle_feedback_admin, _handle_af_admin, _handle_epay_admin]
    for h in handlers:
        if h(self, c, u, api, method):
            return True
    return False
