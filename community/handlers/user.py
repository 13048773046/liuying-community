# -*- coding: utf-8 -*-
"""流萤社区 · 用户域接口：版块树/话题/等级/装扮/表情/偏好/签到/任务/举报/拉黑/
互动通知/官方通知/活动/私信(二期)/资料。
"""
import os
import re
import json
import time
import uuid
import urllib.parse

from common import (db, resolve_token, public_user, add_exp, EXP_RULES, row_dict,
                    task_progress, claim_task, level_from_exp, LEVEL_THRESHOLDS,
                    rate_limit, official_msg, notify, user_mini,
                    member_level_now, is_blocked, blocked_by,
                    FILES_DIR)


def _uid(c, handler):
    return resolve_token(c, handler.headers.get("Authorization", ""))


def _body(h):
    return h._json_body() or {}


# ---------------- 版块 / 话题 ----------------
def _handle_boards(self, c, u, api, method):
    if api != "/boards":
        return False
    rows = c.execute("SELECT * FROM community_boards WHERE active=1 ORDER BY sort ASC, created ASC"
                     ).fetchall()
    nodes = [row_dict(r) for r in rows]
    children = {}
    for n in nodes:
        children.setdefault(n["parent_id"], []).append(n)
    tree = []
    seen = set()

    def build(pid, depth):
        for n in children.get(pid, []):
            if n["id"] in seen or depth > 3:
                continue
            seen.add(n["id"])
            item = {"id": n["id"], "name": n["name"], "parentId": n["parent_id"],
                    "icon": n["icon"], "color": n["color"], "postCount": n["post_count"],
                    "children": build(n["id"], depth + 1)}
            tree.append(item) if pid == "" else None
            if pid != "":
                pass
        return [{"id": n["id"], "name": n["name"], "parentId": n["parent_id"],
                 "icon": n["icon"], "color": n["color"], "postCount": n["post_count"],
                 "children": build(n["id"], depth + 1)} for n in children.get(pid, [])
                if n["id"] not in seen and depth <= 3] if pid != "" else tree

    # 简化：直接用递归构建（避免上面混乱）
    tree = []

    def build2(pid):
        out = []
        for n in children.get(pid, []):
            out.append({"id": n["id"], "name": n["name"], "parentId": n["parent_id"],
                        "icon": n["icon"], "color": n["color"],
                        "postCount": n["post_count"],
                        "children": build2(n["id"])})
        return out

    tree = build2("")
    c.commit()
    self._ok({"list": tree})
    return True


def _handle_topics(self, c, u, api, method):
    if api != "/topics":
        return False
    query = urllib.parse.parse_qs(u.query)
    hot = (query.get("hot") or ["0"])[0] == "1"
    if hot:
        rows = c.execute("SELECT name, post_count FROM community_topics"
                         " ORDER BY post_count DESC LIMIT 30").fetchall()
    else:
        rows = c.execute("SELECT name, post_count FROM community_topics ORDER BY created DESC LIMIT 100").fetchall()
    c.commit()
    self._ok({"list": [{"name": r[0], "count": r[1]} for r in rows]})
    return True


# ---------------- 等级 ----------------
def _handle_level(self, c, u, api, method):
    uid = _uid(c, self)
    if api == "/level/rules":
        c.commit()
        self._ok({"rules": EXP_RULES, "thresholds": LEVEL_THRESHOLDS})
        return True
    if api == "/level/me":
        if not uid:
            self._err(401, "未登录")
            return True
        row = c.execute("SELECT exp, level FROM community_exp WHERE user_id=?", (uid,)).fetchone()
        exp = row[0] if row else 0
        level = row[1] if row else 0
        # 进度：当前等级到下一级
        nxt = LEVEL_THRESHOLDS[level + 1] if level + 1 < len(LEVEL_THRESHOLDS) else None
        cur = LEVEL_THRESHOLDS[level]
        progress = 1.0 if nxt is None else (exp - cur) / (nxt - cur)
        c.commit()
        self._ok({"exp": exp, "level": level, "nextThreshold": nxt,
                  "progress": round(progress, 4)})
        return True
    return False


# ---------------- 装扮（头像框） ----------------
def _handle_frames(self, c, u, api, method):
    uid = _uid(c, self)
    if api == "/frames":
        rows = c.execute("SELECT * FROM community_frames WHERE active=1 ORDER BY sort ASC"
                         ).fetchall()
        c.commit()
        self._ok({"list": [row_dict(r) for r in rows]})
        return True
    if api == "/frame/mine":
        if not uid:
            self._err(401, "未登录")
            return True
        row = c.execute("SELECT frame_id FROM community_user_frames WHERE user_id=?", (uid,)).fetchone()
        c.commit()
        self._ok({"frameId": row[0] if row else ""})
        return True
    if api == "/frame/equip" and method == "POST":
        if not uid:
            self._err(401, "未登录")
            return True
        body = _body(self)
        fid = (body.get("frameId") or "").strip()
        if fid:
            ok = c.execute("SELECT 1 FROM community_frames WHERE id=? AND active=1", (fid,)).fetchone()
            if not ok:
                self._err(404, "头像框不存在")
                return True
        row = c.execute("SELECT 1 FROM community_user_frames WHERE user_id=?", (uid,)).fetchone()
        if row:
            c.execute("UPDATE community_user_frames SET frame_id=?, updated=? WHERE user_id=?",
                      (fid, time.time(), uid))
        else:
            c.execute("INSERT INTO community_user_frames(user_id,frame_id,updated) VALUES(?,?,?)",
                      (uid, fid, time.time()))
        c.commit()
        self._ok({"frameId": fid})
        return True
    return False


# ---------------- 表情包 ----------------
def _handle_emojis(self, c, u, api, method):
    uid = _uid(c, self)
    if api == "/emojis":
        query = urllib.parse.parse_qs(u.query)
        cat = (query.get("category") or [""])[0].strip()
        if cat:
            rows = c.execute("SELECT * FROM community_emojis WHERE active=1 AND category=?"
                             " ORDER BY sort ASC", (cat,)).fetchall()
        else:
            rows = c.execute("SELECT * FROM community_emojis WHERE active=1 ORDER BY category, sort"
                             ).fetchall()
        c.commit()
        self._ok({"list": [{"id": r[0], "code": r[1], "image": r[2],
                            "category": r[3]} for r in rows]})
        return True
    if api == "/emojis/favs":
        if not uid:
            self._err(401, "未登录")
            return True
        rows = c.execute(
            "SELECT e.id, e.code, e.image, e.category FROM community_emojis e"
            " JOIN community_user_emojis f ON f.emoji_id=e.id WHERE f.user_id=?"
            " ORDER BY f.created DESC", (uid,)).fetchall()
        c.commit()
        self._ok({"list": [{"id": r[0], "code": r[1], "image": r[2], "category": r[3]}
                           for r in rows]})
        return True
    m = re.match(r"^/emoji/fav$", api)
    if m and method in ("POST", "DELETE"):
        if not uid:
            self._err(401, "未登录")
            return True
        body = _body(self)
        eid = (body.get("emojiId") or "").strip()
        if not c.execute("SELECT 1 FROM community_emojis WHERE id=?", (eid,)).fetchone():
            self._err(404, "表情不存在")
            return True
        if method == "POST":
            c.execute("INSERT OR IGNORE INTO community_user_emojis(user_id,emoji_id,created) VALUES(?,?,?)",
                      (uid, eid, time.time()))
        else:
            c.execute("DELETE FROM community_user_emojis WHERE user_id=? AND emoji_id=?", (uid, eid))
        c.commit()
        self._ok({"fav": method == "POST"})
        return True
    return False


# ---------------- 偏好（通知/隐私/主题） ----------------
def _handle_prefs(self, c, u, api, method):
    if api != "/prefs":
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    if method == "GET":
        row = c.execute("SELECT * FROM community_user_prefs WHERE user_id=?", (uid,)).fetchone()
        if not row:
            c.commit()
            self._ok({"notifyMask": {}, "quietStart": "", "quietEnd": "",
                      "commentPerm": 0, "profileVisible": 0, "theme": "dark"})
            return True
        d = row_dict(row)
        try:
            mask = json.loads(d.get("notify_mask") or "{}")
        except Exception:
            mask = {}
        c.commit()
        self._ok({"notifyMask": mask, "quietStart": d.get("quiet_start", ""),
                  "quietEnd": d.get("quiet_end", ""),
                  "commentPerm": d.get("comment_perm", 0),
                  "profileVisible": d.get("profile_visible", 0),
                  "theme": d.get("theme", "dark")})
        return True
    body = _body(self)
    quiet_start = (body.get("quietStart") or "").strip()[:8]
    quiet_end = (body.get("quietEnd") or "").strip()[:8]
    comment_perm = int(body.get("commentPerm") or 0)
    if comment_perm not in (0, 1, 2):
        comment_perm = 0
    profile_visible = 1 if body.get("profileVisible") else 0
    theme = (body.get("theme") or "dark").strip()
    if theme not in ("dark", "light"):
        theme = "dark"
    mask = body.get("notifyMask")
    if not isinstance(mask, dict):
        mask = {}
    row = c.execute("SELECT 1 FROM community_user_prefs WHERE user_id=?", (uid,)).fetchone()
    if row:
        c.execute(
            "UPDATE community_user_prefs SET notify_mask=?, quiet_start=?, quiet_end=?,"
            " comment_perm=?, profile_visible=?, theme=?, updated=? WHERE user_id=?",
            (json.dumps(mask, ensure_ascii=False), quiet_start, quiet_end,
             comment_perm, profile_visible, theme, time.time(), uid))
    else:
        c.execute(
            "INSERT INTO community_user_prefs(user_id,notify_mask,quiet_start,quiet_end,"
            " comment_perm,profile_visible,theme,updated) VALUES(?,?,?,?,?,?,?,?)",
            (uid, json.dumps(mask, ensure_ascii=False), quiet_start, quiet_end,
             comment_perm, profile_visible, theme, time.time()))
    c.commit()
    self._ok({"saved": True})
    return True


# ---------------- 签到 / 任务 ----------------
def _handle_signin(self, c, u, api, method):
    uid = _uid(c, self)
    if api == "/signins":
        if not uid:
            self._err(401, "未登录")
            return True
        rows = c.execute("SELECT day FROM community_signins WHERE user_id=? ORDER BY day DESC LIMIT 30",
                         (uid,)).fetchall()
        c.commit()
        self._ok({"list": [r[0] for r in rows]})
        return True
    if api == "/signin" and method == "POST":
        if not uid:
            self._err(401, "未登录")
            return True
        if not rate_limit(self, "signin"):
            self._err(429, "操作过于频繁")
            return True
        today = time.strftime("%Y-%m-%d")
        exists = c.execute("SELECT 1 FROM community_signins WHERE user_id=? AND day=?",
                           (uid, today)).fetchone()
        if exists:
            self._err(400, "今日已签到")
            return True
        c.execute("INSERT INTO community_signins(user_id,day,created) VALUES(?,?,?)",
                  (uid, today, time.time()))
        # 连续签到：昨日是否签到
        yday = time.strftime("%Y-%m-%d", time.localtime(time.time() - 86400))
        streak = 1
        row = c.execute("SELECT 1 FROM community_signins WHERE user_id=? AND day=?",
                        (uid, yday)).fetchone()
        if row:
            # 往前数连续天数
            d = time.time() - 86400
            while c.execute("SELECT 1 FROM community_signins WHERE user_id=? AND day=?",
                            (uid, time.strftime("%Y-%m-%d", time.localtime(d)))).fetchone():
                streak += 1
                d -= 86400
        gain = EXP_RULES["signin"]
        if streak >= 7:
            gain += EXP_RULES["signin_streak"]
        add_exp(c, uid, gain)
        task_progress(c, uid, "t_signin3", 1)
        c.commit()
        self._ok({"day": today, "streak": streak, "exp": gain,
                  "msg": "签到成功 +%d 经验" % gain})
        return True
    return False


def _handle_tasks(self, c, u, api, method):
    if api != "/tasks" and not re.match(r"^/tasks/[\w\-]+/claim$", api):
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    if api == "/tasks":
        rows = c.execute("SELECT * FROM community_tasks WHERE active=1 ORDER BY type, created"
                         ).fetchall()
        out = []
        for r in rows:
            d = row_dict(r)
            prog = c.execute("SELECT progress, done, claimed FROM community_user_tasks"
                             " WHERE user_id=? AND task_id=?", (uid, d["id"])).fetchone()
            out.append({"id": d["id"], "name": d["name"], "type": d["type"],
                        "target": d["target"], "rewardExp": d["reward_exp"],
                        "progress": prog[0] if prog else 0,
                        "done": prog[1] if prog else 0,
                        "claimed": prog[2] if prog else 0})
        c.commit()
        self._ok({"list": out})
        return True
    m = re.match(r"^/tasks/([\w\-]+)/claim$", api)
    if m and method == "POST":
        ok, msg = claim_task(c, uid, m.group(1))
        c.commit()
        if ok:
            self._ok({"claimed": True, "msg": msg})
        else:
            self._err(400, msg)
        return True
    return False


# ---------------- 举报 / 拉黑 ----------------
def _handle_report(self, c, u, api, method):
    if api != "/report":
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    if not rate_limit(self, "report"):
        self._err(429, "操作过于频繁")
        return True
    body = _body(self)
    ttype = (body.get("targetType") or "").strip()
    tid = (body.get("targetId") or "").strip()
    reason = (body.get("reason") or "").strip()[:200]
    if ttype not in ("post", "comment") or not tid:
        self._err(400, "参数错误")
        return True
    if not reason:
        self._err(400, "请填写举报理由")
        return True
    c.execute(
        "INSERT INTO community_reports(id,target_type,target_id,user_id,reason,created)"
        " VALUES(?,?,?,?,?,?)",
        (uuid.uuid4().hex, ttype, tid, uid, reason, time.time()))
    c.commit()
    self._ok({"reported": True, "msg": "已收到举报，我们会尽快处理"})
    return True


def _handle_block(self, c, u, api, method):
    if api != "/blocks" and not re.match(r"^/block/[\w\-]+$", api):
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    m = re.match(r"^/block/([\w\-]+)$", api)
    if m:
        target = m.group(1)
        if target == uid:
            self._err(400, "不能拉黑自己")
            return True
        if not c.execute("SELECT 1 FROM users WHERE id=?", (target,)).fetchone():
            self._err(404, "用户不存在")
            return True
        if method == "POST":
            if not rate_limit(self, "block"):
                self._err(429, "操作过于频繁")
                return True
            c.execute("INSERT OR IGNORE INTO community_blocks(user_id,blocked_id,created) VALUES(?,?,?)",
                      (uid, target, time.time()))
            c.commit()
            self._ok({"blocked": True})
        elif method == "DELETE":
            c.execute("DELETE FROM community_blocks WHERE user_id=? AND blocked_id=?",
                      (uid, target))
            c.commit()
            self._ok({"blocked": False})
        return True
    if api == "/blocks":
        rows = c.execute("SELECT b.blocked_id, u.name, u.avatar FROM community_blocks b"
                         " JOIN users u ON u.id=b.blocked_id WHERE b.user_id=? ORDER BY b.created DESC",
                         (uid,)).fetchall()
        c.commit()
        self._ok({"list": [{"id": r[0], "name": r[1] or "", "avatar": r[2] or ""} for r in rows]})
        return True
    return False


# ---------------- 互动通知 / 官方通知 ----------------
def _handle_notifications(self, c, u, api, method):
    uid = _uid(c, self)
    if api == "/notifications/unread":
        if not uid:
            self._ok({"unread": 0, "officialUnread": 0})
            return True
        n = c.execute("SELECT COUNT(*) FROM notifications WHERE user_id=? AND is_read=0"
                      " AND type != 'official' AND is_deleted=0", (uid,)).fetchone()[0]
        read = c.execute("SELECT last_read FROM community_official_read WHERE user_id=?",
                         (uid,)).fetchone()
        since = read[0] if read else 0
        om = c.execute("SELECT COUNT(*) FROM community_official_messages WHERE created>?"
                       " AND (receiver_user_id='' OR receiver_user_id=?)",
                       (since, uid)).fetchone()[0]
        c.commit()
        self._ok({"unread": n, "officialUnread": om})
        return True
    if api == "/notifications":
        if not uid:
            self._err(401, "未登录")
            return True
        query = urllib.parse.parse_qs(u.query)
        group = (query.get("group") or [""])[0].strip()
        page = max(1, int((query.get("page") or ["1"])[0] or 1))
        size = min(50, max(1, int((query.get("size") or ["20"])[0] or 20)))
        where = "user_id=? AND is_deleted=0"
        args = [uid]
        if group == "mention":
            where += " AND type='community_mention'"
        rows = c.execute(
            "SELECT * FROM notifications WHERE %s ORDER BY created DESC LIMIT ? OFFSET ?"
            % where, args + [size, (page - 1) * size]).fetchall()
        out = []
        for r in rows:
            d = row_dict(r)
            out.append({"id": d["id"], "type": d["type"], "title": d["title"] or "",
                        "content": d["content"] or "", "fromUserId": d["from_user_id"] or "",
                        "fromUserName": d["from_user_name"] or "",
                        "isRead": d["is_read"], "created": d["created"]})
        c.commit()
        self._ok({"list": out, "page": page, "size": size, "hasMore": len(rows) == size})
        return True
    if api == "/notifications/read" and method == "POST":
        if not uid:
            self._err(401, "未登录")
            return True
        body = _body(self)
        nid = (body.get("id") or "").strip()
        if nid:
            c.execute("UPDATE notifications SET is_read=1 WHERE id=? AND user_id=?", (nid, uid))
        else:
            c.execute("UPDATE notifications SET is_read=1 WHERE user_id=? AND is_deleted=0", (uid,))
        c.commit()
        self._ok({"read": True})
        return True
    return False


def _handle_official(self, c, u, api, method):
    uid = _uid(c, self)
    if api == "/official-messages":
        if not uid:
            self._err(401, "未登录")
            return True
        query = urllib.parse.parse_qs(u.query)
        after = float((query.get("after") or ["0"])[0] or 0)
        rows = c.execute(
            "SELECT * FROM community_official_messages WHERE created>?"
            " AND (receiver_user_id='' OR receiver_user_id=?) ORDER BY created ASC LIMIT 100",
            (after, uid)).fetchall()
        c.commit()
        # 表列序：id, content, sender_name, receiver_user_id, created
        self._ok({"list": [{"id": r[0], "content": r[1], "senderName": r[2],
                            "created": r[4]} for r in rows]})
        return True
    if api == "/official-messages/read" and method == "POST":
        if not uid:
            self._err(401, "未登录")
            return True
        c.execute("INSERT OR REPLACE INTO community_official_read(user_id,last_read) VALUES(?,?)",
                  (uid, time.time()))
        c.commit()
        self._ok({"read": True})
        return True
    return False


# ---------------- 活动 ----------------
def _handle_activities(self, c, u, api, method):
    uid = _uid(c, self)
    m = re.match(r"^/activities/([\w\-]+)$", api)
    if m:
        row = c.execute("SELECT * FROM community_activities WHERE id=?", (m.group(1),)).fetchone()
        if not row:
            self._err(404, "活动不存在")
            return True
        d = row_dict(row)
        c.commit()
        self._ok({"activity": {"id": d["id"], "topicId": d["topic_id"], "title": d["title"],
                               "desc": d["desc"], "rewardExp": d["reward_exp"],
                               "startAt": d["start_at"], "endAt": d["end_at"],
                               "status": d["status"]}})
        return True
    if api == "/activities":
        now = time.time()
        rows = c.execute(
            "SELECT * FROM community_activities WHERE start_at<=? AND (end_at=0 OR end_at>=?)"
            " ORDER BY created DESC LIMIT 20", (now, now)).fetchall()
        c.commit()
        self._ok({"list": [{"id": r[0], "topicId": r[1], "title": r[2], "desc": r[3],
                            "rewardExp": r[4], "startAt": r[5], "endAt": r[6],
                            "status": r[7]} for r in rows]})
        return True
    return False


# ---------------- 私信（二期接口本期设计） ----------------
def _handle_chat(self, c, u, api, method):
    if not (api == "/conversations" or api == "/messages"
            or re.match(r"^/conversations/[\w\-]+$", api)):
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    if api == "/conversations":
        rows = c.execute(
            "SELECT * FROM community_conversations WHERE user_a=? OR user_b=?"
            " ORDER BY last_time DESC LIMIT 50", (uid, uid)).fetchall()
        out = []
        for r in rows:
            d = row_dict(r)
            other = d["user_b"] if d["user_a"] == uid else d["user_a"]
            unread = d["unread_a"] if d["user_a"] != uid else d["unread_b"]
            uinfo = user_mini(c, other)
            out.append({"id": d["id"], "peer": uinfo, "lastMsg": d["last_msg"],
                        "lastTime": d["last_time"], "unread": unread})
        c.commit()
        self._ok({"list": out})
        return True
    m = re.match(r"^/conversations/([\w\-]+)$", api)
    if m and method == "POST":
        peer = m.group(1)
        if peer == uid:
            self._err(400, "不能与自己私信")
            return True
        if is_blocked(c, uid, peer) or blocked_by(c, uid, peer):
            self._err(403, "无法发送消息（已拉黑）")
            return True
        row = c.execute(
            "SELECT * FROM community_conversations WHERE (user_a=? AND user_b=?) OR (user_a=? AND user_b=?)",
            (uid, peer, peer, uid)).fetchone()
        if row:
            conv_id = row[0]
        else:
            conv_id = uuid.uuid4().hex
            c.execute("INSERT INTO community_conversations(id,user_a,user_b,created)"
                      " VALUES(?,?,?,?)", (conv_id, uid, peer, time.time()))
        c.commit()
        self._ok({"conversationId": conv_id})
        return True
    if api == "/messages" and method == "GET":
        query = urllib.parse.parse_qs(u.query)
        conv = (query.get("conv_id") or [""])[0].strip()
        page = max(1, int((query.get("page") or ["1"])[0] or 1))
        size = min(50, max(1, int((query.get("size") or ["20"])[0] or 20)))
        row = c.execute("SELECT * FROM community_conversations WHERE id=?", (conv,)).fetchone()
        if not row:
            self._err(404, "会话不存在")
            return True
        rows = c.execute(
            "SELECT * FROM community_messages WHERE conv_id=? ORDER BY created DESC LIMIT ? OFFSET ?",
            (conv, size, (page - 1) * size)).fetchall()
        rows = list(reversed(rows))
        # 标记已读
        if row[1] == uid:
            c.execute("UPDATE community_conversations SET unread_a=0 WHERE id=?", (conv,))
        else:
            c.execute("UPDATE community_conversations SET unread_b=0 WHERE id=?", (conv,))
        c.commit()
        self._ok({"list": [{"id": r[0], "sender": r[2], "content": r[3], "type": r[4],
                            "created": r[5], "readAt": r[6]} for r in rows]})
        return True
    if api == "/messages" and method == "POST":
        if not rate_limit(self, "msg"):
            self._err(429, "发送过于频繁")
            return True
        body = _body(self)
        conv = (body.get("conversationId") or "").strip()
        content = (body.get("content") or "").strip()[:500]
        mtype = (body.get("type") or "text").strip()
        if mtype not in ("text", "image", "emoji"):
            mtype = "text"
        row = c.execute("SELECT * FROM community_conversations WHERE id=?", (conv,)).fetchone()
        if not row:
            self._err(404, "会话不存在")
            return True
        peer = row[1] if row[2] == uid else row[2]
        if is_blocked(c, uid, peer) or blocked_by(c, uid, peer):
            self._err(403, "无法发送消息（已拉黑）")
            return True
        mid = uuid.uuid4().hex
        c.execute("INSERT INTO community_messages(id,conv_id,sender,content,type,created) VALUES(?,?,?,?,?,?)",
                  (mid, conv, uid, content, mtype, time.time()))
        if row[1] == uid:
            c.execute("UPDATE community_conversations SET last_msg=?, last_time=?, unread_b=unread_b+1 WHERE id=?",
                      (content[:60], time.time(), conv))
        else:
            c.execute("UPDATE community_conversations SET last_msg=?, last_time=?, unread_a=unread_a+1 WHERE id=?",
                      (content[:60], time.time(), conv))
        c.commit()
        self._ok({"id": mid, "created": time.time()})
        return True
    return False


# ---------------- 用户资料 ----------------
def _handle_profile(self, c, u, api, method):
    m = re.match(r"^/user/([\w\-]+)/profile$", api)
    if not m:
        return False
    target = m.group(1)
    viewer = _uid(c, self)
    pub = public_user(c, target)
    if not pub:
        self._err(404, "用户不存在")
        return True
    if pub["banned"]:
        self._err(403, "该用户已被封禁")
        return True
    # 隐私：仅关注可见
    prefs = c.execute("SELECT profile_visible FROM community_user_prefs WHERE user_id=?",
                      (target,)).fetchone()
    if prefs and prefs[0] == 1 and viewer != target:
        if not (viewer and c.execute("SELECT 1 FROM follows WHERE follower_id=? AND following_id=?",
                                     (viewer, target)).fetchone()):
            self._err(403, "该用户主页仅关注者可见")
            return True
    # 关注关系
    following = bool(viewer and c.execute(
        "SELECT 1 FROM follows WHERE follower_id=? AND following_id=?", (viewer, target)).fetchone())
    followers = c.execute("SELECT COUNT(*) FROM follows WHERE following_id=?", (target,)).fetchone()[0]
    followings = c.execute("SELECT COUNT(*) FROM follows WHERE follower_id=?", (target,)).fetchone()[0]
    pub["following"] = following
    pub["followers"] = followers
    pub["followings"] = followings
    c.commit()
    self._ok({"user": pub})
    return True


# ---------------- 当前用户（/user/me）与关注动作 ----------------
def _handle_me(self, c, u, api, method):
    """GET /user/me → 当前登录用户完整资料（与 /user/{uid}/profile 同构）。"""
    if api != "/user/me" or method != "GET":
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录或登录已过期")
        return True
    pub = public_user(c, uid)
    if not pub:
        self._err(404, "用户不存在")
        return True
    followers = c.execute("SELECT COUNT(*) FROM follows WHERE following_id=?", (uid,)).fetchone()[0]
    followings = c.execute("SELECT COUNT(*) FROM follows WHERE follower_id=?", (uid,)).fetchone()[0]
    pub["following"] = False
    pub["followers"] = followers
    pub["followings"] = followings
    c.commit()
    self._ok({"user": pub})
    return True


def _handle_follow(self, c, u, api, method):
    """POST/DELETE /user/{uid}/follow → 关注/取关（写音乐 follows 表，零侵入互通）。"""
    m = re.match(r"^/user/([\w\-]+)/follow$", api)
    if not m:
        return False
    target = m.group(1)
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录或登录已过期")
        return True
    if uid == target:
        self._err(400, "不能关注自己")
        return True
    if not public_user(c, target):
        self._err(404, "用户不存在")
        return True
    exists = c.execute("SELECT 1 FROM follows WHERE follower_id=? AND following_id=?",
                       (uid, target)).fetchone()
    if method == "DELETE" or (method == "POST" and exists):
        c.execute("DELETE FROM follows WHERE follower_id=? AND following_id=?", (uid, target))
        c.commit()
        self._ok({"following": False,
                  "followers": c.execute("SELECT COUNT(*) FROM follows WHERE following_id=?",
                                         (target,)).fetchone()[0]})
        return True
    if method == "POST":
        c.execute("INSERT OR IGNORE INTO follows(follower_id,following_id,created) VALUES(?,?,?)",
                  (uid, target, time.time()))
        try:
            me = public_user(c, uid)
            notify(c, target, "community_interact", "新关注",
                   "%s 关注了你" % ((me or {}).get("name") or "一位新朋友"), from_uid=uid,
                   from_name=(me or {}).get("name") or "")
        except Exception:
            pass  # 通知失败不影响关注结果
        c.commit()
        self._ok({"following": True,
                  "followers": c.execute("SELECT COUNT(*) FROM follows WHERE following_id=?",
                                         (target,)).fetchone()[0]})
        return True
    self._err(405, "仅支持 POST（关注）/ DELETE（取关）")
    return True


def dispatch(self, c, u, api, method):
    handlers = [_handle_boards, _handle_topics, _handle_level, _handle_frames,
                _handle_emojis, _handle_prefs, _handle_signin, _handle_tasks,
                _handle_report, _handle_block, _handle_notifications,
                _handle_official, _handle_activities, _handle_chat,
                _handle_profile, _handle_me, _handle_follow]
    for h in handlers:
        if h(self, c, u, api, method):
            return True
    return False
