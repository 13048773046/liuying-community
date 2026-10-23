# -*- coding: utf-8 -*-
"""流萤社区 · 公共层：DB 连接 / token 鉴权（复用音乐 tokens 表逻辑）/ 限流 / 经验等级 / 通知 / 公共装饰。

零侵入：只读 users/tokens/follows；按授权写 notifications（互动通知两边可见）。
"""
import os
import re
import json
import time
import uuid
import sqlite3
import threading
import secrets
from collections import deque
from html import escape as html_escape

BASE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.environ.get("COMMUNITY_DB", "/www/wwwroot/music/tracks.db")
FILES_DIR = os.path.join(BASE, "files")

# ---------- DB ----------
_db_lock = threading.Lock()
_db_inited = False


def db():
    global _db_inited
    if not _db_inited:
        with _db_lock:
            if not _db_inited:
                from schema import init_schema
                init_schema()
                _db_inited = True
    c = sqlite3.connect(DB_PATH, timeout=10)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA busy_timeout=5000")
    c.execute("PRAGMA synchronous=NORMAL")
    return c


# ---------- Token 鉴权（与音乐 resolve_token 同逻辑：30s TTL 缓存） ----------
_TOKEN_CACHE = {}
_TOKEN_CACHE_LOCK = threading.Lock()
_TOKEN_CACHE_TTL = 30.0


def resolve_token(c, auth_header):
    """Authorization: Bearer <token> → user_id 或 None（30s 内存缓存，读音乐 tokens 表）"""
    if not auth_header:
        return None
    scheme, _, tok = auth_header.partition(" ")
    if scheme.lower() != "bearer" or not tok.strip():
        return None
    tok = tok.strip()
    now = time.time()
    with _TOKEN_CACHE_LOCK:
        hit = _TOKEN_CACHE.get(tok)
        if hit and hit[1] > now:
            return hit[0]
    row = c.execute("SELECT user_id FROM tokens WHERE token=? AND expires>?",
                    (tok, now)).fetchone()
    uid = row[0] if row else None
    with _TOKEN_CACHE_LOCK:
        if uid is not None:
            _TOKEN_CACHE[tok] = (uid, now + _TOKEN_CACHE_TTL)
        else:
            _TOKEN_CACHE.pop(tok, None)
    return uid


# ---------- 限流（IP + token 双维度，各行为独立） ----------
class _RateLimiter:
    def __init__(self):
        self._lock = threading.Lock()
        self._hits = {}

    def allow(self, key, limit, window):
        now = time.time()
        with self._lock:
            dq = self._hits.setdefault(key, deque())
            while dq and now - dq[0] > window:
                dq.popleft()
            if len(dq) >= limit:
                return False
            dq.append(now)
            return True


_RATE = _RateLimiter()

# 行为限流表：发帖/视频/评论/点赞/分享/上传/投票/举报/签到/私信/搜索
RATE_LIMITS = {
    "post": (30, 3600), "video": (10, 3600), "comment": (60, 3600),
    "like": (120, 3600), "share": (60, 3600), "fav": (120, 3600),
    "upload_image": (20, 3600), "upload_video": (10, 3600),
    "poll": (60, 3600), "report": (20, 3600), "block": (30, 3600),
    "signin": (2, 3600), "search": (120, 3600), "msg": (60, 3600),
    "admin": (240, 60), "track": (300, 60),
}


def rate_limit(handler, name):
    """按 IP + token 双维度限流；返回 False 表示超限。"""
    ip = client_ip(handler)
    spec = RATE_LIMITS.get(name, (60, 60))
    limit, window = spec
    # token 维度（可选）
    tok = ""
    auth = handler.headers.get("Authorization", "")
    if auth:
        tok = auth.replace("Bearer ", "").strip()[:24]
    keys = ["%s:%s" % (name, ip)]
    if tok:
        keys.append("%s:%s" % (name, tok))
    for k in keys:
        if not _RATE.allow(k, limit, window):
            return False
    return True


def client_ip(handler):
    xri = handler.headers.get("X-Real-IP", "")
    if xri:
        return xri.strip()
    xff = handler.headers.get("X-Forwarded-For", "")
    if xff:
        parts = [p.strip() for p in xff.split(",") if p.strip()]
        if parts:
            return parts[-1]
    return handler.client_address[0] if handler.client_address else ""


# ---------- 用户公开信息（共享 users 表只读 + 社区扩展） ----------
def public_user(c, uid, viewer_uid=None):
    """用户资料 = 音乐 users 表公开字段（认证/头衔/会员互通）+ 社区扩展（等级/头像框/管理员/社区会员）。"""
    row = c.execute(
        "SELECT id,account,name,avatar,created,gender,signature,city,"
        "title,verified,verified_label,member,member_expire,svip_expire,banned"
        " FROM users WHERE id=?", (uid,)).fetchone()
    if not row:
        return None
    now = time.time()
    member = ""
    if row[13] and row[13] > now:
        member = "svip" if (row[12] == "svip" or (row[13] and row[13] > now and row[12] == "svip")) else member
    # 音乐会员按到期时间判定
    if row[12] and row[12] > now:
        member = "vip"
    if row[13] and row[13] > now:
        member = "svip"
    exp_row = c.execute("SELECT exp, level FROM community_exp WHERE user_id=?",
                        (uid,)).fetchone()
    frame_row = c.execute("SELECT frame_id FROM community_user_frames WHERE user_id=?",
                          (uid,)).fetchone()
    admin_row = c.execute("SELECT level FROM community_admins WHERE user_id=?",
                          (uid,)).fetchone()
    mem_row = c.execute("SELECT level, expire FROM community_members WHERE user_id=?",
                        (uid,)).fetchone()
    out = {
        "id": uid,
        "account": row[1] or "",
        "name": row[2] or "",
        "avatar": row[3] or "",
        "created": row[4] or 0,
        "gender": row[5] or "",
        "signature": row[6] or "",
        "city": row[7] or "",
        "title": row[8] or "",
        "verified": row[9] or "",
        "verifiedLabel": row[10] or "",
        "member": member,
        "memberExpire": row[12] or 0,
        "svipExpire": row[13] or 0,
        "banned": row[14] or 0,
        "level": exp_row[1] if exp_row else 0,
        "exp": exp_row[0] if exp_row else 0,
        "frameId": frame_row[0] if frame_row else "",
        "adminLevel": admin_row[0] if admin_row else 0,
        "adminName": "社区超级管理员" if (admin_row and admin_row[0] == 1)
                     else ("社区管理员" if admin_row else ""),
        "cMember": (mem_row[0] or "") if (mem_row and mem_row[1] and mem_row[1] > now) else "",
        "cMemberExpire": mem_row[1] if mem_row else 0,
    }
    return out


def user_mini(c, uid):
    """轻量作者信息（帖子/评论附带）。"""
    row = c.execute("SELECT name,avatar FROM users WHERE id=?", (uid,)).fetchone()
    if not row:
        return {"id": uid, "name": "已注销", "avatar": ""}
    admin_row = c.execute("SELECT level FROM community_admins WHERE user_id=?", (uid,)).fetchone()
    exp_row = c.execute("SELECT level FROM community_exp WHERE user_id=?", (uid,)).fetchone()
    frame_row = c.execute("SELECT frame_id FROM community_user_frames WHERE user_id=?", (uid,)).fetchone()
    out = {"id": uid, "name": row[0] or "", "avatar": row[1] or "",
           "level": exp_row[0] if exp_row else 0,
           "frameId": frame_row[0] if frame_row else "",
           "adminLevel": admin_row[0] if admin_row else 0,
           "adminName": "社区超级管理员" if (admin_row and admin_row[0] == 1)
                        else ("社区管理员" if admin_row else "")}
    return out


# ---------- 经验 / 等级 ----------
LEVEL_THRESHOLDS = [0, 100, 300, 600, 1000, 1500, 2200, 3200, 4500, 6000, 8000]

EXP_RULES = {
    "post_text": 10, "post_video": 20, "post_poll": 12,
    "comment": 2, "be_liked_text": 2, "be_liked_video": 3,
    "be_comment": 2, "be_shared": 3, "be_mentioned": 1,
    "like_other": 1, "signin": 5, "signin_streak": 20,
    "vote": 2, "daily_active": 5,
}


def level_from_exp(exp):
    lv = 0
    for i, t in enumerate(LEVEL_THRESHOLDS):
        if exp >= t:
            lv = i
        else:
            break
    return lv


def add_exp(c, uid, amount):
    """累加经验并判定升级。返回 (new_exp, old_level, new_level, leveled_up)。"""
    if amount <= 0:
        return None, None, None, False
    row = c.execute("SELECT exp, level FROM community_exp WHERE user_id=?",
                    (uid,)).fetchone()
    old_exp = row[0] if row else 0
    old_level = row[1] if row else 0
    new_exp = old_exp + amount
    new_level = level_from_exp(new_exp)
    if row:
        c.execute("UPDATE community_exp SET exp=?, level=?, updated=? WHERE user_id=?",
                  (new_exp, new_level, time.time(), uid))
    else:
        c.execute("INSERT INTO community_exp(user_id, exp, level, updated) VALUES(?,?,?,?)",
                  (uid, new_exp, new_level, time.time()))
    return new_exp, old_level, new_level, (new_level > old_level)


def notify(c, uid, ntype, title, content, from_uid="", from_name="", extra=None):
    """写共享 notifications 表（互动通知两边可见）+ WS 实时推送。extra: dict 附加字段。"""
    nid = uuid.uuid4().hex
    c.execute(
        "INSERT INTO notifications(id,user_id,type,title,content,from_user_id,from_user_name,is_read,created)"
        " VALUES(?,?,?,?,?,?,?,0,?)",
        (nid, uid, ntype, title, content, from_uid, from_name, time.time()))
    # WS 实时推送（连接存在时；静默失败）
    try:
        from handlers import ws as H_WS
        n = c.execute("SELECT COUNT(*) FROM notifications WHERE user_id=? AND is_read=0"
                      " AND type!='official' AND is_deleted=0", (uid,)).fetchone()[0]
        H_WS.ws_push(uid, {"kind": "notification",
                           "notification": {"id": nid, "type": ntype, "title": title,
                                             "content": content, "fromUserId": from_uid,
                                             "fromUserName": from_name, "isRead": 0,
                                             "created": time.time()},
                           "unread": n})
    except Exception:
        pass
    return nid


def official_msg(c, uid, content):
    """写社区官方通知（完全独立于音乐 official_messages）。"""
    omid = uuid.uuid4().hex
    c.execute(
        "INSERT INTO community_official_messages(id,content,created,sender_name,receiver_user_id)"
        " VALUES(?,?,?,?,?)",
        (omid, content, time.time(), "流萤社区官方", uid))
    return omid


# ---------- 内容装饰（帖子/评论带作者+互动态+管理态） ----------
def decorate_post(c, p, viewer_uid=None):
    """posts 行 → 对外 JSON。p 为 sqlite Row（含所有字段，按列名访问需先转 dict）。"""
    d = row_dict(p)
    uid = d.get("user_id", "")
    author = user_mini(c, uid)
    liked = False
    faved = False
    later = False
    voted = False
    if viewer_uid:
        liked = bool(c.execute(
            "SELECT 1 FROM community_post_likes WHERE user_id=? AND post_id=?",
            (viewer_uid, d["id"])).fetchone())
        faved = bool(c.execute(
            "SELECT 1 FROM community_favorites WHERE user_id=? AND post_id=? AND kind='fav'",
            (viewer_uid, d["id"])).fetchone())
        later = bool(c.execute(
            "SELECT 1 FROM community_favorites WHERE user_id=? AND post_id=? AND kind='later'",
            (viewer_uid, d["id"])).fetchone())
        voted = bool(c.execute(
            "SELECT 1 FROM community_poll_votes WHERE user_id=? AND post_id=?",
            (viewer_uid, d["id"])).fetchone())
    poll = None
    if d.get("poll"):
        try:
            poll = json.loads(d["poll"])
            poll["voted"] = voted
            poll["closed"] = (poll.get("endAt", 0) and poll["endAt"] <= time.time())
        except Exception:
            poll = None
    # 审核/下架可见性：作者与管理员可见原始状态；他人仅可见已通过+未下架
    show_status = True
    return {
        "id": d["id"],
        "type": d.get("type", "text"),
        "content": d.get("content", ""),
        "images": json.loads(d.get("images") or "[]"),
        "video": d.get("video", ""),
        "cover": d.get("cover", ""),
        "duration": d.get("duration", 0),
        "boardId": d.get("board_id", ""),
        "tag": d.get("tag", ""),
        "topic": json.loads(d.get("topic") or "[]"),
        "mentions": json.loads(d.get("mentions") or "[]"),
        "poll": poll,
        "likeCount": d.get("like_count", 0),
        "commentCount": d.get("comment_count", 0),
        "shareCount": d.get("share_count", 0),
        "liked": liked,
        "faved": faved,
        "later": later,
        "sticky": d.get("sticky", 0),
        "featured": d.get("featured", 0),
        "takenDown": d.get("taken_down", 0),
        "takenDownReason": d.get("taken_down_reason", ""),
        "auditStatus": d.get("audit_status", 0),
        "auditReason": d.get("audit_reason", ""),
        "created": d.get("created", 0),
        "author": author,
    }


def decorate_comment(c, r, viewer_uid=None):
    d = row_dict(r)
    author = user_mini(c, d.get("user_id", ""))
    liked = False
    if viewer_uid:
        liked = bool(c.execute(
            "SELECT 1 FROM community_post_comment_likes WHERE user_id=? AND comment_id=?",
            (viewer_uid, d["id"])).fetchone())
    return {
        "id": d["id"],
        "postId": d.get("post_id", ""),
        "content": d.get("content", ""),
        "images": json.loads(d.get("images") or "[]"),
        "sticker": d.get("sticker", ""),
        "likeCount": d.get("like_count", 0),
        "liked": liked,
        "pinned": d.get("pinned", 0),
        "created": d.get("created", 0),
        "author": author,
    }


def check_sensitive(c, text):
    """返回命中的敏感词列表；空=安全。level=0 拦截 / level=1 转审。"""
    hits = []
    if not text:
        return hits
    for row in c.execute("SELECT word, level FROM community_sensitive_words WHERE active=1"):
        w, lv = row[0], row[1]
        if w and w in text:
            hits.append({"word": w, "level": lv})
    return hits


def parse_mentions(c, text):
    """从富文本提取 @昵称 → [{id, name}]（客户端已传 mentions 时以此为准）。"""
    out = []
    for m in re.finditer(r"@([\u4e00-\u9fa5A-Za-z0-9_]{1,32})", text or ""):
        name = m.group(1)
        row = c.execute("SELECT id FROM users WHERE name=?", (name,)).fetchone()
        if row and row[0] not in [x["id"] for x in out]:
            out.append({"id": row[0], "name": name})
    return out


def parse_topics(text):
    """从富文本提取 #话题#（兼容 #话题 与 #话题#）。"""
    out = []
    for m in re.finditer(r"#([^#\n\s]{1,30})#?", text or ""):
        t = m.group(1).strip()
        if t and t not in out:
            out.append(t)
    return out


def ensure_topics(c, names):
    """话题幂等入库 + 计数。返回话题 name 列表。"""
    out = []
    now = time.time()
    for n in names:
        n = n.strip()
        if not n:
            continue
        row = c.execute("SELECT id FROM community_topics WHERE name=?", (n,)).fetchone()
        if row:
            c.execute("UPDATE community_topics SET post_count=post_count+1 WHERE id=?", (row[0],))
            out.append(n)
        else:
            c.execute("INSERT INTO community_topics(id,name,post_count,created) VALUES(?,?,1,?)",
                      (uuid.uuid4().hex, n, now))
            out.append(n)
    return out


def admin_required(c, handler):
    """管理鉴权：X-Community-Admin-Token → (token, level) 或 None。"""
    tok = handler.headers.get("X-Community-Admin-Token", "").strip()
    if not tok:
        return None
    row = c.execute("SELECT token, level FROM community_admins WHERE token=?", (tok,)).fetchone()
    return row


def admin_log(c, tok, action, target_type="", target_id="", detail=""):
    c.execute("INSERT INTO community_admin_logs(id,admin_token,action,target_type,target_id,detail,created)"
              " VALUES(?,?,?,?,?,?,?)",
              (uuid.uuid4().hex, tok, action, target_type, target_id, detail, time.time()))


def is_blocked(c, viewer_uid, target_uid):
    if not viewer_uid or not target_uid:
        return False
    return bool(c.execute(
        "SELECT 1 FROM community_blocks WHERE user_id=? AND blocked_id=?",
        (viewer_uid, target_uid)).fetchone())


def blocked_by(c, viewer_uid, target_uid):
    """对方拉黑了我（双向屏蔽）。"""
    if not viewer_uid or not target_uid:
        return False
    return bool(c.execute(
        "SELECT 1 FROM community_blocks WHERE user_id=? AND blocked_id=?",
        (target_uid, viewer_uid)).fetchone())


def task_progress(c, uid, tid, add=0):
    """任务进度累计；达到目标置 done=1。"""
    row = c.execute("SELECT progress, done, claimed FROM community_user_tasks WHERE user_id=? AND task_id=?",
                    (uid, tid)).fetchone()
    task = c.execute("SELECT id, target, reward_exp FROM community_tasks WHERE id=?", (tid,)).fetchone()
    if not task:
        return
    target = task[1]
    prog = (row[0] if row else 0) + add
    done = 1 if (row and row[1]) else (1 if prog >= target else 0)
    if row:
        c.execute("UPDATE community_user_tasks SET progress=?, done=? WHERE user_id=? AND task_id=?",
                  (prog, done, uid, tid))
    else:
        c.execute("INSERT INTO community_user_tasks(user_id, task_id, progress, done, claimed) VALUES(?,?,?,?,0)",
                  (uid, tid, prog, done))
    return done


def claim_task(c, uid, tid):
    """领取任务奖励。返回 (ok, msg)。"""
    row = c.execute("SELECT progress, done, claimed FROM community_user_tasks WHERE user_id=? AND task_id=?",
                    (uid, tid)).fetchone()
    task = c.execute("SELECT id, name, reward_exp FROM community_tasks WHERE id=?", (tid,)).fetchone()
    if not task:
        return False, "任务不存在"
    if not row or not row[1]:
        return False, "任务未完成"
    if row[2]:
        return False, "已领取"
    c.execute("UPDATE community_user_tasks SET claimed=1 WHERE user_id=? AND task_id=?",
              (uid, tid))
    add_exp(c, uid, task[2])
    return True, "已领取 +%d 经验" % task[2]


def member_level_now(c, uid):
    """社区会员状态。"""
    row = c.execute("SELECT level, expire FROM community_members WHERE user_id=?", (uid,)).fetchone()
    if row and row[1] and row[1] > time.time():
        return row[0], row[1]
    return "", 0


def image_magic_ok(data, ext):
    """图片魔数校验。ext 含点，如 .jpg。"""
    if not data:
        return False
    magic = {
        ".jpg": (b"\xff\xd8\xff",), ".jpeg": (b"\xff\xd8\xff",),
        ".png": (b"\x89PNG\r\n\x1a\n",),
        ".webp": (b"RIFF", b"WEBP"),
        ".gif": (b"GIF87a", b"GIF89a"),
    }.get(ext.lower())
    if not magic:
        return False
    return any(data[:len(m)] == m for m in magic)


def video_magic_ok(data):
    """视频魔数（mp4/webm）。"""
    if not data or len(data) < 12:
        return False
    if data[4:8] == b"ftyp":
        return True
    if data[:4] == b"\x1aE\xdf\xa3":
        return True
    return False


def is_json(text):
    try:
        json.loads(text or "")
        return True
    except Exception:
        return False


def row_dict(row):
    """sqlite3.Row → dict（dict() 对 Row 不可用，需显式按 keys 转换）。"""
    if row is None:
        return {}
    return {k: row[k] for k in row.keys()}
