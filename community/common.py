# -*- coding: utf-8 -*-
"""流萤社区 · 公共层：DB 连接 / token 鉴权（复用音乐 tokens 表逻辑）/ 限流 / 经验等级 / 通知 / 公共装饰。

零侵入：只读 users/tokens/follows；按授权写 notifications（互动通知两边可见）。
"""
import os
import re
import json
import time
import uuid
import hashlib
import sqlite3
import threading
import secrets
from collections import deque
from html import escape as html_escape

BASE = os.path.dirname(os.path.abspath(__file__))

from core.settings import settings
from core.security import (
    client_ip as trusted_client_ip,
    client_ip_sort_key,
    rate_limit_retry_after,
)

DB_PATH = settings.db_path
FILES_DIR = settings.files_dir

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
_TOKEN_CACHE_TTL = 15.0


def invalidate_token(tok):
    """登出/风控撤销后立即清掉鉴权缓存，避免 15s 残留。"""
    if not tok:
        return
    with _TOKEN_CACHE_LOCK:
        _TOKEN_CACHE.pop(str(tok).strip(), None)


def resolve_token(c, auth_header):
    """Authorization: Bearer <token> → user_id 或 None（15s 内存缓存，读音乐 tokens 表）"""
    if not auth_header:
        return None
    scheme, _, tok = auth_header.partition(" ")
    if scheme.lower() != "bearer" or not tok.strip():
        return None
    tok = tok.strip()
    if len(tok) > 256:
        return None
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
        self._last_clean = time.time()

    def _cleanup(self, now, window):
        # 只在有窗口过期时清理，避免请求高峰扫描全表。
        if now - self._last_clean < max(60, window):
            return
        self._last_clean = now
        stale = [k for k, dq in self._hits.items()
                 if not dq or now - dq[-1] > max(window, 3600)]
        for k in stale:
            self._hits.pop(k, None)

    def allow(self, key, limit, window):
        now = time.time()
        with self._lock:
            self._cleanup(now, window)
            dq = self._hits.setdefault(key, deque())
            while dq and now - dq[0] > window:
                dq.popleft()
            if len(dq) >= limit:
                return False
            dq.append(now)
            return True

    def reset(self, key):
        with self._lock:
            self._hits.pop(key, None)


_RATE = _RateLimiter()

# 行为限流表：登录/验证码比普通业务严格一个数量级；上传仍按小时控量。
RATE_LIMITS = {
    "captcha": (8, 600), "captcha_cap_challenge": (20, 600), "captcha_cap_redeem": (30, 600),
    "login": (20, 300), "login_email": (30, 300), "login_code": (30, 300),
    "send_email": (10, 600), "send_login_code": (10, 600),
    "post": (30, 3600), "video": (10, 3600), "comment": (60, 3600),
    "like": (120, 3600), "share": (60, 3600), "fav": (120, 3600),
    "upload_image": (20, 3600), "upload_video": (10, 3600),
    "upload_attachment": (20, 3600), "topic_create": (20, 3600),
    "emoji_custom": (20, 3600),
    "poll": (60, 3600), "report": (20, 3600), "block": (30, 3600),
    "signin": (2, 3600), "search": (120, 3600), "msg": (60, 3600),
    "invite_phone_send": (3, 600), "invite_phone_confirm": (8, 300),
    "invite_withdraw": (5, 3600), "invite_info": (120, 60),
    "invite_click": (60, 600), "invite_share": (60, 600), "invite_qr": (30, 60),
    "admin": (180, 60), "track": (300, 60),
}


def _token_scope(handler):
    auth = handler.headers.get("Authorization", "") or ""
    if not auth:
        return ""
    tok = auth.replace("Bearer ", "").strip()
    if not tok:
        return ""
    return hashlib.sha256(tok.encode("utf-8")).hexdigest()[:16]


def rate_limit(handler, name):
    """按 IP + token 双维度限流；返回 False 表示超限。"""
    ip = client_ip(handler)
    spec = RATE_LIMITS.get(name, (60, 60))
    limit, window = spec
    keys = ["%s:%s" % (name, ip)]
    tok = _token_scope(handler)
    if tok:
        keys.append("%s:%s" % (name, tok))
    for k in keys:
        if not _RATE.allow(k, limit, window):
            handler._rate_retry_after = rate_limit_retry_after(window)
            return False
    return True


def rate_limit_key(handler, name, subject, limit, window):
    """给登录账号等业务主键单独加锁；subject 不落明文，调用方传 hash。"""
    ip = client_ip(handler)
    key = "%s:%s:%s" % (name, ip, str(subject or "")[:64])
    if not _RATE.allow(key, limit, window):
        handler._rate_retry_after = rate_limit_retry_after(window)
        return False
    return True


def reset_rate_limit(handler, name, subject=""):
    ip = client_ip(handler)
    base = "%s:%s" % (name, ip)
    _RATE.reset(base)
    if subject:
        _RATE.reset("%s:%s:%s" % (name, ip, str(subject or "")[:64]))


def client_ip(handler):
    peer = handler.client_address[0] if handler.client_address else ""
    return client_ip_sort_key(trusted_client_ip(
        handler.headers, peer, settings.trusted_proxies))


# ---------- 用户公开信息（共享 users 表只读 + 社区扩展） ----------
_USER_HAS_EMAIL = None


def _user_has_email(c):
    """共享 users 表由音乐服务维护，email 是可选列；缓存探测结果，避免每请求 PRAGMA。"""
    global _USER_HAS_EMAIL
    if _USER_HAS_EMAIL is None:
        try:
            cols = {r[1] for r in c.execute("PRAGMA table_info(users)").fetchall()}
            _USER_HAS_EMAIL = "email" in cols
        except Exception:
            _USER_HAS_EMAIL = False
    return _USER_HAS_EMAIL


def public_user(c, uid, viewer_uid=None):
    """用户资料 = 音乐 users 表公开字段（认证/头衔/会员互通）+ 社区扩展（等级/头像框/管理员/社区会员）。"""
    email_expr = "email" if _user_has_email(c) else "'' AS email"
    row = c.execute(
        "SELECT id,account,name,avatar,created,gender,signature,city,"
        "title,verified,verified_label,member,member_expire,svip_expire,banned,background_image,age," + email_expr +
        " FROM users WHERE id=?", (uid,)).fetchone()
    if not row:
        return None
    now = time.time()
    # 社区会员只读 community_members；音乐会员不进入社区展示，两套体系各自独立
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
        "isAi": (row[10] or "").strip().upper() == "AI",
        "member": "",
        "memberExpire": 0,
        "svipExpire": 0,
        "banned": row[14] or 0,
        "background": row[15] or "",
        "age": row[16] or 0,
        "email": (row[17] or "") if (viewer_uid and viewer_uid == uid) else "",
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


def user_mini(c, uid, viewer_uid=None):
    """轻量作者信息（帖子/评论附带）。

    认证、AI 标识与「当前访客是否已关注」必须随作者一起下发，否则前端在
    信息流/帖子详情/评论里拿不到关系，只能逐页补拉，容易出现「有的页面有 V、
    有的页面没有」以及关注按钮状态错误。
    """
    row = c.execute(
        "SELECT name,avatar,verified,verified_label FROM users WHERE id=?",
        (uid,)).fetchone()
    if not row:
        return {"id": uid, "name": "已注销", "avatar": "", "verified": "",
                "verifiedLabel": "", "isAi": False}
    admin_row = c.execute("SELECT level FROM community_admins WHERE user_id=?", (uid,)).fetchone()
    exp_row = c.execute("SELECT level FROM community_exp WHERE user_id=?", (uid,)).fetchone()
    frame_row = c.execute("SELECT frame_id FROM community_user_frames WHERE user_id=?", (uid,)).fetchone()
    label = (row[3] or "").strip()
    out = {"id": uid, "name": row[0] or "", "avatar": row[1] or "",
           "verified": row[2] or "", "verifiedLabel": label,
           "isAi": label.upper() == "AI",
           "level": exp_row[0] if exp_row else 0,
           "frameId": frame_row[0] if frame_row else "",
           "adminLevel": admin_row[0] if admin_row else 0,
           "adminName": "社区超级管理员" if (admin_row and admin_row[0] == 1)
                        else ("社区管理员" if admin_row else "")}
    if viewer_uid and viewer_uid != uid:
        out["following"] = bool(c.execute(
            "SELECT 1 FROM follows WHERE follower_id=? AND following_id=?",
            (viewer_uid, uid)).fetchone())
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


def record_behavior(c, uid, post_id, event, value=1.0, meta=None):
    """记录个性化推荐行为（轻量、幂等去重）。

    event: view / open / like / unlike / fav / unfav / later / unlater /
           comment / share / vote / not_interested
    - view 30 分钟内同一帖子只记一次，避免刷新详情页把画像刷爆；
    - meta 存事件快照（boardId/topics/authorId），帖子删除后画像仍可用。
    """
    if not uid or not post_id:
        return False
    event = (event or "").strip()[:24]
    if not event:
        return False
    now = time.time()
    if event == "view":
        recent = c.execute(
            "SELECT 1 FROM community_behavior_events"
            " WHERE user_id=? AND post_id=? AND event='view' AND created>=? LIMIT 1",
            (uid, post_id, now - 1800)).fetchone()
        if recent:
            return False
    meta_json = ""
    if meta:
        try:
            meta_json = json.dumps(meta, ensure_ascii=False, separators=(",", ":"))
        except Exception:
            meta_json = ""
    c.execute(
        "INSERT INTO community_behavior_events(id,user_id,post_id,event,value,meta,created)"
        " VALUES(?,?,?,?,?,?,?)",
        (uuid.uuid4().hex, uid, post_id, event, float(value or 0), meta_json[:800], now))
    return True


def notify(c, uid, ntype, title, content, from_uid="", from_name="", extra=None):
    """写共享 notifications 表（互动通知两边可见）+ WS 实时推送。

    extra 可带 postId / commentId：分别落到共享表的 track_id / comment_id，
    客户端据此把通知点回帖子或评论。共享表零改动，不新增列。
    """
    nid = uuid.uuid4().hex
    extra = extra or {}
    post_id = str(extra.get("postId") or "")
    comment_id = str(extra.get("commentId") or "")
    c.execute(
        "INSERT INTO notifications(id,user_id,type,title,content,from_user_id,from_user_name,is_read,created,track_id,comment_id)"
        " VALUES(?,?,?,?,?,?,?,0,?,?,?)",
        (nid, uid, ntype, title, content, from_uid, from_name, time.time(),
         post_id, comment_id))
    # WS 实时推送（连接存在时；静默失败）
    try:
        from handlers import ws as H_WS
        n = c.execute("SELECT COUNT(*) FROM notifications WHERE user_id=? AND is_read=0"
                      " AND type LIKE 'community_%' AND is_deleted=0", (uid,)).fetchone()[0]
        H_WS.ws_push(uid, {"kind": "notification",
                           "notification": {"id": nid, "type": ntype, "title": title,
                                             "content": content, "fromUserId": from_uid,
                                             "fromUserName": from_name, "isRead": 0,
                                             "created": time.time(),
                                             "postId": post_id,
                                             "commentId": comment_id},
                           "unread": n})
    except Exception:
        pass
    return nid


def official_msg(c, uid, content, content_type="text", plain_text=""):
    """写社区官方通知（完全独立于音乐 official_messages）+ WS 实时推送。

    content_type='rich' 时 content 为 rich_text 规范化后的 JSON；plain_text 供
    旧版客户端 / 后台列表 / 推送摘要使用。普通文本通知保持原行为。
    """
    ctype = "rich" if content_type == "rich" else "text"
    omid = uuid.uuid4().hex
    created = time.time()
    c.execute(
        "INSERT INTO community_official_messages"
        "(id,content,created,sender_name,receiver_user_id,content_type,plain_text)"
        " VALUES(?,?,?,?,?,?,?)",
        (omid, content, created, "流萤社区官方", uid, ctype,
         (plain_text or "") if ctype == "rich" else ""))
    c.commit()
    display = (plain_text or "") if ctype == "rich" else content
    message = {"id": omid, "content": display, "senderName": "流萤社区官方",
               "created": created, "contentType": ctype,
               "plainText": display if ctype == "rich" else content}
    if ctype == "rich":
        try:
            message["rich"] = json.loads(content)
        except (TypeError, ValueError):
            message["contentType"] = "text"
    try:
        from handlers import ws as H_WS
        if uid:
            read = c.execute(
                "SELECT last_read FROM community_official_read WHERE user_id=?",
                (uid,)).fetchone()
            since = read[0] if read else 0
            n = c.execute(
                "SELECT COUNT(*) FROM community_official_messages WHERE created>?"
                " AND (receiver_user_id='' OR receiver_user_id=?)",
                (since, uid)).fetchone()[0]
            H_WS.ws_push(uid, {"kind": "official", "message": message,
                               "officialUnread": n})
        else:
            H_WS.ws_broadcast({"kind": "official", "message": message})
    except Exception:
        pass
    return omid


# ---------- 内容装饰（帖子/评论带作者+互动态+管理态） ----------

def _media_name(v):
    """video 字段补扩展名：DB 存无扩展名 id，文件实际为 {id}.mp4。"""
    v = (v or "").strip()
    if v and "." not in v:
        return v + ".mp4"
    return v


def _cover_name(cover, v):
    """cover='auto' → {video}.jpg（首帧封面）；空/其他原样返回。"""
    cover = (cover or "").strip()
    if cover == "auto" and v:
        return _media_name(v)[:-4] + ".jpg"
    return cover


def community_music_media_url(value):
    """把音乐站媒体 URL 改成社区代理 URL，旧帖停服后也能播放/显示。"""
    if not isinstance(value, str):
        return value
    for prefix, kind in (
        (settings.music_public_base.rstrip("/") + "/files/", "files"),
        (settings.music_public_base.rstrip("/") + "/api/cover/", "cover"),
    ):
        if value.startswith(prefix):
            return settings.public_base + "/music/" + kind + "/" + value[len(prefix):]
    return value


def community_music_json(raw):
    """配乐字段是 JSON 字符串；重写其中的媒体 URL，解析失败原样返回。"""
    if not isinstance(raw, str) or not raw.strip():
        return raw
    try:
        data = json.loads(raw)
    except Exception:
        return raw
    if not isinstance(data, dict):
        return raw
    out = dict(data)
    for key in ("url", "cover"):
        if key in out:
            out[key] = community_music_media_url(out[key])
    return json.dumps(out, ensure_ascii=False)


def _json_list(raw):
    try:
        value = json.loads(raw or "[]")
        return value if isinstance(value, list) else []
    except Exception:
        return []


def decorate_post(c, p, viewer_uid=None):
    """posts 行 → 对外 JSON。p 为 sqlite Row（含所有字段，按列名访问需先转 dict）。"""
    d = row_dict(p)
    uid = d.get("user_id", "")
    author = user_mini(c, uid, viewer_uid)
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
        "video": _media_name(d.get("video", "")),
        "cover": _cover_name(d.get("cover", ""), d.get("video", "")),
        "duration": d.get("duration", 0),
        "music": community_music_json(d.get("music", "")),
        "audioVolume": 100 if d.get("audio_volume") is None else d.get("audio_volume"),
        "musicVolume": 50 if d.get("music_volume") is None else d.get("music_volume"),
        "boardId": d.get("board_id", ""),
        "tag": d.get("tag", ""),
        "topic": json.loads(d.get("topic") or "[]"),
        "mentions": json.loads(d.get("mentions") or "[]"),
        "poll": poll,
        "attachments": _json_list(d.get("attachments")),
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
    author = user_mini(c, d.get("user_id", ""), viewer_uid)
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


MAX_ATTACHMENTS = 2
MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024
ATTACHMENT_MIME = {
    ".pdf": "application/pdf",
    ".doc": "application/msword",
    ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".xls": "application/vnd.ms-excel",
    ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ".ppt": "application/vnd.ms-powerpoint",
    ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ".txt": "text/plain; charset=utf-8",
    ".md": "text/markdown; charset=utf-8",
    ".csv": "text/csv; charset=utf-8",
    ".zip": "application/zip",
    ".rar": "application/vnd.rar",
    ".7z": "application/x-7z-compressed",
}


def clean_attachment_label(raw, fallback="附件"):
    """下载文件名只保留展示用安全字符，不允许 CR/LF 或路径。"""
    label = str(raw or "").replace("\\", "/").split("/")[-1]
    label = re.sub(r"[\x00-\x1f\x7f]", "", label).strip().strip('"')
    if not label:
        label = fallback
    return label[:120]


def normalize_attachments(uid, raw):
    """校验客户端回传的附件元信息，只信任上传接口生成的归属文件名。

    返回 (list, error)。文件真实大小以磁盘为准，避免客户端伪造大小。
    """
    if raw in (None, "", []):
        return [], None
    if not isinstance(raw, list):
        return None, "附件参数格式错误"
    if len(raw) > MAX_ATTACHMENTS:
        return None, "最多上传 %d 个附件" % MAX_ATTACHMENTS
    out = []
    prefix = "community_attach_%s_" % (uid or "")[:8]
    for item in raw:
        if not isinstance(item, dict):
            return None, "附件参数格式错误"
        name = str(item.get("name") or "").strip()
        if not name or not name.startswith(prefix):
            return None, "附件不存在或不属于当前账号"
        if not re.match(r"^community_attach_[0-9a-zA-Z]+_[0-9a-zA-Z]+(\.[a-z0-9]+)$", name):
            return None, "附件名不合法"
        ext = os.path.splitext(name)[1].lower()
        if ext not in ATTACHMENT_MIME:
            return None, "不支持这种附件格式"
        real = os.path.realpath(os.path.join(FILES_DIR, name))
        root = os.path.realpath(FILES_DIR)
        if not real.startswith(root + os.sep) or not os.path.isfile(real):
            return None, "附件文件不存在，请重新上传"
        size = os.path.getsize(real)
        if size <= 0 or size > MAX_ATTACHMENT_BYTES:
            return None, "附件大小异常"
        out.append({
            "name": name,
            "label": clean_attachment_label(item.get("label") or item.get("originalName") or name),
            "size": size,
            "ext": ext.lstrip("."),
            "mime": ATTACHMENT_MIME[ext],
        })
    return out, None


def bump_board_count(c, board_id, delta):
    """版块计数向上汇总：子分类发帖也计入父版块，沿祖先链逐层更新。"""
    if not board_id or not delta:
        return
    seen = set()
    cur = board_id
    while cur and cur not in seen:
        seen.add(cur)
        row = c.execute("SELECT parent_id FROM community_boards WHERE id=?", (cur,)).fetchone()
        if not row:
            break
        c.execute("UPDATE community_boards SET post_count=MAX(0, post_count+?) WHERE id=?",
                  (int(delta), cur))
        cur = (row[0] or "").strip()


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
    # 一次性成就任务只累计到目标，避免任务中心出现 5/1 这种失真进度。
    if add > 0:
        prog = min(prog, target)
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


MEMBER_LEVELS = ("member", "svip")
MEMBER_RANK = {"": 0, "member": 1, "svip": 2}
MEMBER_LABEL = {"member": "VIP", "svip": "SVIP"}
# 各档表情收藏上限
MEMBER_EMOJI_LIMIT = {"": 500, "member": 2000, "svip": 5000}


def member_level_now(c, uid):
    """社区会员状态 → (level, expire)。过期或非法值一律按未开通处理。"""
    if not uid:
        return "", 0
    row = c.execute("SELECT level, expire FROM community_members WHERE user_id=?", (uid,)).fetchone()
    if row and row[1] and row[1] > time.time() and row[0] in MEMBER_LEVELS:
        return row[0], row[1]
    return "", 0


def member_rank(level):
    return MEMBER_RANK.get(level or "", 0)


def member_emoji_limit(level):
    return MEMBER_EMOJI_LIMIT.get(level or "", MEMBER_EMOJI_LIMIT[""])


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
