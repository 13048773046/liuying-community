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
                    rate_limit, official_msg, notify, user_mini, image_magic_ok,
                    member_level_now, member_rank, member_emoji_limit,
                    is_blocked, blocked_by, check_sensitive,
                    FILES_DIR)
from core.settings import settings

MAX_CUSTOM_EMOJIS = 50
MAX_CUSTOM_EMOJI_BYTES = 2 * 1024 * 1024
ALLOWED_EMOJI_EXT = (".png", ".jpg", ".jpeg", ".webp", ".gif")


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


def _topic_affinity(c, uid):
    """近 60 天话题偏好：从行为事件快照 topics 聚合，按时间衰减。"""
    if not uid:
        return {}
    now = time.time()
    cutoff = now - 60 * 86400
    rows = c.execute(
        "SELECT meta, value, created FROM community_behavior_events"
        " WHERE user_id=? AND created>=? AND value>0 ORDER BY created DESC LIMIT 2000",
        (uid, cutoff)).fetchall()
    scores = {}
    for meta, value, created in rows:
        try:
            topics = json.loads(meta or "{}").get("topics") or []
        except Exception:
            topics = []
        decay = max(0.25, 1.0 - (now - float(created or now)) / (60 * 86400))
        for name in topics[:10]:
            name = str(name or "").strip()
            if not name:
                continue
            scores[name] = scores.get(name, 0.0) + float(value or 1) * decay
    return scores


def _handle_topics(self, c, u, api, method):
    if api != "/topics":
        return False
    query = urllib.parse.parse_qs(u.query)
    uid = _uid(c, self)
    if method == "POST":
        if not uid:
            self._err(401, "未登录")
            return True
        if not rate_limit(self, "topic_create"):
            self._err(429, "创建话题过于频繁，请稍后再试")
            return True
        body = _body(self)
        name = re.sub(r"[\x00-\x1f\x7f]", "", str(body.get("name") or ""))
        name = name.replace("#", "").strip()
        name = re.sub(r"\s+", " ", name)
        if not name:
            self._err(400, "话题名不能为空")
            return True
        if len(name) > 30:
            self._err(400, "话题名最多 30 个字")
            return True
        hits = check_sensitive(c, name)
        if any(h["level"] == 0 for h in hits):
            self._err(400, "话题名包含敏感词")
            return True
        row = c.execute("SELECT id, name FROM community_topics WHERE name=? COLLATE NOCASE",
                        (name,)).fetchone()
        if row:
            c.commit()
            self._ok({"name": row[1], "count": c.execute(
                "SELECT post_count FROM community_topics WHERE id=?", (row[0],)).fetchone()[0],
                "mine": bool(c.execute(
                    "SELECT 1 FROM community_topics WHERE id=? AND created_by=?",
                    (row[0], uid)).fetchone()), "created": False})
            return True
        now = time.time()
        tid = uuid.uuid4().hex
        c.execute("INSERT INTO community_topics(id,name,post_count,created_by,created)"
                  " VALUES(?,?,0,?,?)", (tid, name, uid, now))
        c.commit()
        self._ok({"name": name, "count": 0, "mine": True, "created": True})
        return True
    if method not in ("GET", "HEAD"):
        return False
    q = (query.get("q") or [""])[0].strip()
    hot = (query.get("hot") or ["0"])[0] == "1"
    if q:
        rows = c.execute("SELECT name, post_count, created_by FROM community_topics"
                         " WHERE name LIKE ? ORDER BY post_count DESC, created DESC LIMIT 60",
                         ("%" + q + "%",)).fetchall()
        c.commit()
        self._ok({"list": [{"name": r[0], "count": r[1],
                            "mine": bool(uid and r[2] == uid)} for r in rows]})
        return True
    if hot:
        rows = c.execute("SELECT name, post_count, created_by FROM community_topics"
                         " ORDER BY post_count DESC LIMIT 60").fetchall()
        if uid:
            affinity = _topic_affinity(c, uid)
            ranked = []
            for name, count, created_by in rows:
                affinity_score = affinity.get(name, 0.0)
                score = affinity_score * 6.0 + (max(0, int(count or 0)) ** 0.5)
                reason = "因为你常看「%s」" % name if affinity_score > 0 else "社区热门"
                ranked.append((score, name, count, reason, created_by))
            ranked.sort(key=lambda x: (-x[0], -int(x[2] or 0), x[1]))
            rows = ranked[:30]
            c.commit()
            self._ok({"list": [{"name": r[1], "count": r[2], "reason": r[3],
                                "mine": bool(uid and r[4] == uid)} for r in rows]})
            return True
        c.commit()
        self._ok({"list": [{"name": r[0], "count": r[1],
                            "mine": bool(uid and r[2] == uid)} for r in rows]})
        return True
    rows = c.execute("SELECT name, post_count, created_by FROM community_topics"
                     " ORDER BY created DESC LIMIT 100").fetchall()
    c.commit()
    self._ok({"list": [{"name": r[0], "count": r[1],
                        "mine": bool(uid and r[2] == uid)} for r in rows]})
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
            ok = c.execute("SELECT member_level FROM community_frames WHERE id=? AND active=1",
                           (fid,)).fetchone()
            if not ok:
                self._err(404, "头像框不存在")
                return True
            need = (ok[0] or "").strip()
            if need and member_rank(member_level_now(c, uid)[0]) < member_rank(need):
                c.commit()
                self._err(403, "该头像框需要 %s 会员" % ("SVIP" if need == "svip" else "VIP"))
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
            rows = c.execute("SELECT * FROM community_emojis WHERE active=1"
                             " AND COALESCE(owner_id,'')='' AND category=?"
                             " ORDER BY sort ASC", (cat,)).fetchall()
        else:
            rows = c.execute("SELECT * FROM community_emojis WHERE active=1"
                             " AND COALESCE(owner_id,'')='' ORDER BY category, sort"
                             ).fetchall()
        c.commit()
        self._ok({"list": [{"id": r[0], "code": r[1], "image": r[2],
                            "category": r[3]} for r in rows]})
        return True
    if api == "/emojis/favs":
        if not uid:
            self._err(401, "未登录")
            return True
        level = member_level_now(c, uid)[0]
        _limit = member_emoji_limit(level)
        rows = c.execute(
            "SELECT e.id, e.code, e.image, e.category FROM community_emojis e"
            " JOIN community_user_emojis f ON f.emoji_id=e.id WHERE f.user_id=?"
            " ORDER BY f.created DESC", (uid,)).fetchall()
        c.commit()
        self._ok({"list": [{"id": r[0], "code": r[1], "image": r[2], "category": r[3]}
                           for r in rows],
                  "limit": _limit, "memberLevel": level})
        return True
    m = re.match(r"^/emoji/fav$", api)
    if m and method in ("POST", "DELETE"):
        if not uid:
            self._err(401, "未登录")
            return True
        body = _body(self)
        eid = (body.get("emojiId") or "").strip()
        erow = c.execute("SELECT owner_id FROM community_emojis WHERE id=?", (eid,)).fetchone()
        if not erow:
            self._err(404, "表情不存在")
            return True
        owner = (erow[0] or "").strip()
        if owner and owner != uid:
            self._err(403, "这是其他用户的自定义表情")
            return True
        if method == "POST":
            level = member_level_now(c, uid)[0]
            limit = member_emoji_limit(level)
            used = c.execute("SELECT COUNT(*) FROM community_user_emojis WHERE user_id=?",
                             (uid,)).fetchone()[0]
            has = c.execute("SELECT 1 FROM community_user_emojis WHERE user_id=? AND emoji_id=?",
                            (uid, eid)).fetchone()
            if not has and used >= limit:
                c.commit()
                self._err(400, "表情收藏已满（%d/%d），开通会员可扩容" % (used, limit))
                return True
            c.execute("INSERT OR IGNORE INTO community_user_emojis(user_id,emoji_id,created) VALUES(?,?,?)",
                      (uid, eid, time.time()))
        else:
            c.execute("DELETE FROM community_user_emojis WHERE user_id=? AND emoji_id=?", (uid, eid))
        c.commit()
        self._ok({"fav": method == "POST"})
        return True
    if api == "/emojis/custom":
        if method != "POST":
            self._err(405, "仅支持 POST")
            return True
        if not uid:
            self._err(401, "未登录")
            return True
        if not rate_limit(self, "emoji_custom"):
            self._err(429, "上传表情过于频繁，请稍后再试")
            return True
        fields, files = self._multipart(MAX_CUSTOM_EMOJI_BYTES + 8192)
        if files is None:
            self._err(400, "上传数据无效")
            return True
        fdata, fname = None, ""
        for _, (fn, data) in (files or {}).items():
            if data:
                fdata, fname = data, fn
                break
        if not fdata:
            self._err(400, "缺少表情图片")
            return True
        ext = os.path.splitext(fname)[1].lower()
        if ext not in ALLOWED_EMOJI_EXT:
            self._err(400, "只支持 PNG / JPG / WEBP / GIF")
            return True
        if len(fdata) > MAX_CUSTOM_EMOJI_BYTES:
            self._err(413, "表情图片过大（≤2MB）")
            return True
        if not image_magic_ok(fdata[:32], ext):
            self._err(400, "表情图片格式校验失败")
            return True
        custom_count = c.execute(
            "SELECT COUNT(*) FROM community_emojis WHERE owner_id=?", (uid,)).fetchone()[0]
        if custom_count >= MAX_CUSTOM_EMOJIS:
            self._err(400, "自定义表情最多 %d 个" % MAX_CUSTOM_EMOJIS)
            return True
        level = member_level_now(c, uid)[0]
        limit = member_emoji_limit(level)
        used = c.execute("SELECT COUNT(*) FROM community_user_emojis WHERE user_id=?",
                         (uid,)).fetchone()[0]
        if used >= limit:
            self._err(400, "表情收藏已满（%d/%d），开通会员可扩容" % (used, limit))
            return True
        os.makedirs(FILES_DIR, exist_ok=True)
        out = "community_img_emoji_%s_%s%s" % (
            uid[:8], uuid.uuid4().hex[:10], ".jpg" if ext == ".jpeg" else ext)
        with open(os.path.join(FILES_DIR, out), "wb") as f:
            f.write(fdata)
        eid = uuid.uuid4().hex
        code = "custom_%s_%s" % (uid[:8], uuid.uuid4().hex[:8])
        c.execute(
            "INSERT INTO community_emojis(id,code,image,category,sort,active,created,owner_id)"
            " VALUES(?,?,?,?,0,1,?,?)",
            (eid, code, out, "我的表情", time.time(), uid))
        c.execute("INSERT OR IGNORE INTO community_user_emojis(user_id,emoji_id,created)"
                  " VALUES(?,?,?)", (uid, eid, time.time()))
        c.commit()
        self._ok({"id": eid, "code": code, "image": out, "category": "我的表情"})
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
            # 老用户在这些行为埋点上线前可能已经完成过动作，按真实数据补齐，
            # 避免「已经关注了人，任务却还显示进行中」。
            if d["id"] == "t_follow1":
                n = c.execute("SELECT COUNT(*) FROM follows WHERE follower_id=?",
                              (uid,)).fetchone()[0]
                if n > 0:
                    task_progress(c, uid, "t_follow1", 1)
            elif d["id"] == "t_profile":
                cols = {x[1] for x in c.execute("PRAGMA table_info(users)").fetchall()}
                fields = [x for x in ("signature", "gender", "age", "city")
                          if x in cols]
                if fields:
                    row = c.execute("SELECT " + ",".join(fields) + " FROM users WHERE id=?",
                                    (uid,)).fetchone()
                    if row and any(
                            (v > 0 if f == "age" and isinstance(v, (int, float))
                             else bool(str(v or "").strip()))
                            for f, v in zip(fields, row)):
                        task_progress(c, uid, "t_profile", 1)
            prog = c.execute("SELECT progress, done, claimed FROM community_user_tasks"
                             " WHERE user_id=? AND task_id=?", (uid, d["id"])).fetchone()
            done = bool(prog[1]) if prog else False
            claimed = bool(prog[2]) if prog else False
            status = "claimed" if claimed else ("done" if done else "pending")
            out.append({"id": d["id"], "name": d["name"], "type": d["type"],
                        "target": d["target"], "rewardExp": d["reward_exp"],
                        "progress": min(prog[0], d["target"]) if prog else 0,
                        "done": done, "claimed": claimed, "status": status})
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
def _notif_group_condition(group):
    """互动通知分类对应的 SQL 片段（只允许固定枚举，不接受任意输入拼 SQL）。"""
    if group == "like":
        return " AND type LIKE '%like%'"
    if group == "comment":
        return (" AND (type LIKE '%comment%' OR type LIKE '%reply%'"
                " OR type LIKE '%mention%')")
    if group == "follow":
        return " AND (type LIKE '%follow%' OR type LIKE '%interact%')"
    if group == "audit":
        return " AND type LIKE '%audit%'"
    return ""


def _handle_notifications(self, c, u, api, method):
    uid = _uid(c, self)
    if api == "/notifications/unread":
        if not uid:
            self._ok({"unread": 0, "officialUnread": 0, "byType": {}})
            return True
        n = c.execute("SELECT COUNT(*) FROM notifications WHERE user_id=? AND is_read=0"
                      " AND type LIKE 'community_%' AND is_deleted=0", (uid,)).fetchone()[0]
        # 分类角标：与消息页二级入口共用同一套类型归并
        by_type = {"like": 0, "comment": 0, "follow": 0, "audit": 0, "other": 0}
        rows = c.execute(
            "SELECT type, COUNT(*) FROM notifications WHERE user_id=? AND is_read=0"
            " AND type LIKE 'community_%' AND is_deleted=0 GROUP BY type",
            (uid,)).fetchall()
        for ntype, cnt in rows:
            t = (ntype or "").lower()
            if "like" in t:
                by_type["like"] += cnt
            elif "comment" in t or "reply" in t or "mention" in t:
                by_type["comment"] += cnt
            elif "follow" in t or "interact" in t:
                by_type["follow"] += cnt
            elif "audit" in t:
                by_type["audit"] += cnt
            else:
                by_type["other"] += cnt
        read = c.execute("SELECT last_read FROM community_official_read WHERE user_id=?",
                         (uid,)).fetchone()
        since = read[0] if read else 0
        om = c.execute("SELECT COUNT(*) FROM community_official_messages WHERE created>?"
                       " AND (receiver_user_id='' OR receiver_user_id=?)",
                       (since, uid)).fetchone()[0]
        c.commit()
        self._ok({"unread": n, "officialUnread": om, "byType": by_type})
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
        elif group in ("like", "comment", "follow", "audit"):
            # 分类列表在服务端过滤，避免只取到全局前 20 条导致分类列表缺失
            where += _notif_group_condition(group)
        rows = c.execute(
            "SELECT * FROM notifications WHERE %s ORDER BY created DESC LIMIT ? OFFSET ?"
            % where, args + [size, (page - 1) * size]).fetchall()
        out = []
        for r in rows:
            d = row_dict(r)
            from_uid = d["from_user_id"] or ""
            from_user = user_mini(c, from_uid) if from_uid else {}
            out.append({"id": d["id"], "type": d["type"], "title": d["title"] or "",
                        "content": d["content"] or "",
                        "fromUserId": from_uid,
                        "fromUserName": d["from_user_name"] or "",
                        "fromAvatar": from_user.get("avatar", "") if from_user else "",
                        "fromFrameId": from_user.get("frameId", "") if from_user else "",
                        "fromVerified": from_user.get("verified", "") if from_user else "",
                        "fromVerifiedLabel": from_user.get("verifiedLabel", "") if from_user else "",
                        "fromIsAi": bool(from_user.get("isAi")) if from_user else False,
                        "postId": d.get("track_id") or "",
                        "commentId": d.get("comment_id") or "",
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
        group = (body.get("group") or "").strip()
        if nid:
            c.execute("UPDATE notifications SET is_read=1 WHERE id=? AND user_id=?", (nid, uid))
        elif group:
            c.execute("UPDATE notifications SET is_read=1 WHERE user_id=? AND is_deleted=0"
                      " AND type LIKE 'community_%'" + _notif_group_condition(group), (uid,))
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
        # 表列序：id, content, sender_name, receiver_user_id, created,
        #         content_type, plain_text
        out = []
        for r in rows:
            ctype = (r[5] or "text") if len(r) > 5 else "text"
            plain = (r[6] or "") if len(r) > 6 else ""
            # 旧版客户端只认 content；富文本降级成纯文本，避免把 canonical
            # JSON 直接显示成通知正文。新版客户端优先读 rich。
            item = {"id": r[0],
                    "content": plain if ctype == "rich" else r[1],
                    "senderName": r[2], "created": r[4],
                    "contentType": ctype, "plainText": plain}
            if ctype == "rich":
                try:
                    item["rich"] = json.loads(r[1])
                except (TypeError, ValueError):
                    item["contentType"] = "text"
            out.append(item)
        self._ok({"list": out})
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
            "SELECT * FROM community_activities WHERE status=1 AND start_at<=?"
            " AND (end_at=0 OR end_at>=?) ORDER BY created DESC LIMIT 20",
            (now, now)).fetchall()
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
            uinfo = user_mini(c, other, uid)
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


# ---------------- 关注 / 粉丝列表 ----------------
def _handle_user_list(self, c, u, api, method):
    """GET /user/{uid}/followings|followers → 关注/粉丝列表（带认证与当前访客关系）。"""
    m = re.match(r"^/user/([\w\-]+)/(followings|followers)$", api)
    if not m or method != "GET":
        return False
    target, kind = m.group(1), m.group(2)
    q = urllib.parse.parse_qs(u.query)
    page = max(1, int((q.get("page") or ["1"])[0] or 1))
    size = min(50, max(1, int((q.get("size") or ["20"])[0] or 20)))
    viewer = _uid(c, self)
    if kind == "followings":
        rows = c.execute(
            "SELECT following_id FROM follows WHERE follower_id=?"
            " ORDER BY created DESC LIMIT ? OFFSET ?",
            (target, size + 1, (page - 1) * size)).fetchall()
    else:
        rows = c.execute(
            "SELECT follower_id FROM follows WHERE following_id=?"
            " ORDER BY created DESC LIMIT ? OFFSET ?",
            (target, size + 1, (page - 1) * size)).fetchall()
    ids = [r[0] for r in rows[:size] if r[0]]
    out = []
    for uid in ids:
        mini = user_mini(c, uid, viewer)
        pub = public_user(c, uid)
        if not pub or pub.get("banned"):
            continue
        mini["signature"] = pub.get("signature", "")
        mini["title"] = pub.get("title", "")
        mini["verifiedLabel"] = pub.get("verifiedLabel", mini.get("verifiedLabel", ""))
        mini["isAi"] = pub.get("isAi", mini.get("isAi", False))
        out.append(mini)
    c.commit()
    self._ok({"list": out, "page": page, "size": size,
              "hasMore": len(rows) > size})
    return True


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




# ---------------- 编辑资料 / 改绑邮箱 / 头像 ----------------
def _send_bind_email_code(self, c, body):
    from handlers.auth import _send_code
    return _send_code(self, c, body)


def _handle_user_email_code(self, c, u, api, method):
    if api != "/user/email-code" or method != "POST":
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录或登录已过期")
        return True
    return _send_bind_email_code(self, c, _body(self))


def _handle_update_me(self, c, u, api, method):
    if api != "/user/me" or method != "POST":
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录或登录已过期")
        return True
    body = _body(self)
    cols = {r[1] for r in c.execute("PRAGMA table_info(users)").fetchall()}
    updates = {}
    name = (body.get("name") or "").strip()
    if name:
        if len(name) > 24:
            self._err(400, "昵称最多 24 个字")
            return True
        updates["name"] = name
    if "signature" in body:
        sig = (body.get("signature") or "").strip()
        if len(sig) > 100:
            self._err(400, "签名最多 100 个字")
            return True
        updates["signature"] = sig
    if "gender" in body:
        updates["gender"] = (body.get("gender") or "").strip()[:8]
    if "age" in body:
        try:
            age = int(body.get("age") or 0)
        except Exception:
            age = 0
        updates["age"] = max(0, min(age, 150))
    if "city" in body:
        updates["city"] = (body.get("city") or "").strip()[:32]

    email = (body.get("email") or "").strip().lower()
    code = (body.get("code") or "").strip()
    if email:
        if "email" not in cols:
            self._err(503, "共享用户表缺少 email 列")
            return True
        old = c.execute("SELECT email FROM users WHERE id=?", (uid,)).fetchone()
        old_email = (old[0] or "").lower() if old else ""
        if email != old_email:
            if not code:
                self._err(400, "修改邮箱需要验证码")
                return True
            from handlers.auth import _ensure_email_codes
            _ensure_email_codes(c)
            row = c.execute("SELECT code, created, fail_count FROM email_codes WHERE email=?",
                            (email,)).fetchone()
            if not row:
                self._err(400, "验证码错误")
                return True
            if row[0] != code:
                fc = (row[2] or 0) + 1
                if fc >= 5:
                    c.execute("DELETE FROM email_codes WHERE email=?", (email,))
                else:
                    c.execute("UPDATE email_codes SET fail_count=? WHERE email=?", (fc, email))
                c.commit()
                self._err(400, "验证码错误")
                return True
            if time.time() - row[1] > 300:
                self._err(400, "验证码已过期，请重新获取")
                return True
            exists = c.execute("SELECT id FROM users WHERE lower(email)=lower(?) AND id!=?",
                               (email, uid)).fetchone()
            if exists:
                self._err(409, "该邮箱已被其他账号绑定")
                return True
            updates["email"] = email
            if "email_verified" in cols:
                updates["email_verified"] = 1

    if not updates:
        self._ok({"user": public_user(c, uid, uid) or {}})
        return True
    q = "UPDATE users SET " + ",".join(k + "=?" for k in updates) + " WHERE id=?"
    c.execute(q, tuple(updates.values()) + (uid,))
    if "email" in updates:
        c.execute("DELETE FROM email_codes WHERE email=?", (updates["email"],))
    # 完善资料是真实成就任务：资料字段保存成功才推进。
    task_progress(c, uid, "t_profile", 1)
    c.commit()
    self._ok({"user": public_user(c, uid, uid) or {}})
    return True


def _handle_avatar(self, c, u, api, method):
    if api != "/user/me/avatar" or method != "POST":
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录或登录已过期")
        return True
    if not rate_limit(self, "avatar"):
        self._err(429, "上传过于频繁，请稍后再试")
        return True
    length = int(self.headers.get("Content-Length", "0") or 0)
    if length <= 0 or length > 10 * 1024 * 1024 + 8192:
        self._err(413, "头像文件过大（≤10MB）")
        return True
    fields, files = self._multipart(10 * 1024 * 1024 + 8192)
    if files is None:
        self._err(400, "上传数据无效")
        return True
    fdata, fname = None, ""
    for _, (fn, data) in files.items():
        if data:
            fdata, fname = data, fn
            break
    if not fdata:
        self._err(400, "缺少头像文件")
        return True
    ext = os.path.splitext(fname)[1].lower()
    if ext not in (".jpg", ".jpeg", ".png", ".webp", ".gif"):
        ext = ".jpg"
    if not image_magic_ok(fdata[:32], ext):
        self._err(400, "头像格式校验失败")
        return True
    root = settings.music_files_dir
    if not os.path.isdir(root):
        root = "/www/wwwroot/music/data/media/files"
    if not os.path.isdir(root):
        self._err(503, "头像存储目录不可用")
        return True
    out = uid + "_avatar" + (".jpg" if ext == ".jpeg" else ext)
    with open(os.path.join(root, out), "wb") as f:
        f.write(fdata)
    c.execute("UPDATE users SET avatar=? WHERE id=?", (out, uid))
    task_progress(c, uid, "t_profile", 1)
    c.commit()
    self._ok({"avatar": out})
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
    pub = public_user(c, uid, uid)
    if not pub:
        self._err(404, "用户不存在")
        return True
    followers = c.execute("SELECT COUNT(*) FROM follows WHERE following_id=?", (uid,)).fetchone()[0]
    followings = c.execute("SELECT COUNT(*) FROM follows WHERE follower_id=?", (uid,)).fetchone()[0]
    pub["following"] = False
    pub["followers"] = followers
    pub["followings"] = followings
    # 手机号只对当前用户本人返回，列表/公开主页不暴露；APP 编辑资料页用。
    phone_mask = ""
    phone_verified = False
    try:
        p = c.execute(
            "SELECT phone_mask, phone_verified_at FROM community_invite_profiles "
            "WHERE user_id=?", (uid,)).fetchone()
        if p:
            phone_mask = p[0] or ""
            phone_verified = bool(phone_mask)
        if not phone_mask:
            a = c.execute(
                "SELECT phone_mask FROM community_phone_accounts WHERE user_id=?",
                (uid,)).fetchone()
            if a:
                phone_mask = a[0] or ""
                phone_verified = bool(phone_mask)
    except Exception:
        # 邀请/手机号表尚未初始化时不阻断“我的”页。
        pass
    pub["phoneMask"] = phone_mask
    pub["phoneVerified"] = phone_verified
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
        # 关注任务是真实成就任务：首次成功关注即完成。
        task_progress(c, uid, "t_follow1", 1)
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
                _handle_user_list, _handle_profile, _handle_user_email_code, _handle_update_me, _handle_avatar, _handle_me, _handle_follow]
    for h in handlers:
        if h(self, c, u, api, method):
            return True
    return False
