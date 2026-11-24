# -*- coding: utf-8 -*-
"""流小萤 · 社区 AI 核心服务。

边界：
- 所有动作都真实写入社区表（帖子/视频/应用/点赞/评论/收藏/关注/私信）；
- 发布物一律进入既有管理员审核队列，不直接公开；
- 账号资料只能改签名/性别/年龄/城市/背景图/头衔，名字/头像/密码/邮箱与后台权限字段锁定；
- 不做跳转、不写假日志。
"""
import json
import os
import re
import time
import uuid
import urllib.parse

from common import db, row_dict, user_mini, notify, check_sensitive, add_exp
from core.settings import settings
from ai_bot_schema import DEFAULT_POLICY
import ai_bot_media as MEDIA

BOT_ID = os.environ.get("AI_BOT_UID", "ai_liuying_comment")
BOT_NAME = "流小萤"
BOT_PREFIX = BOT_ID[:8]
FILES_DIR = settings.files_dir

PROFILE_FIELDS = {
    "signature": ("signature", 120),
    "age": ("age", 0),
    "city": ("city", 30),
    "background_image": ("background_image", 300),
    "title": ("title", 30),
}


def now():
    return time.time()


def _json(v, default=None):
    try:
        return json.loads(v or "") if isinstance(v, str) else (v if v is not None else default)
    except Exception:
        return default


def _conn(c=None):
    return c if c is not None else db()


# ---------------- 配置 --------------
def get_policy(c=None):
    own = c is None
    c = _conn(c)
    row = c.execute("SELECT value FROM ai_bot_config WHERE key='policy'").fetchone()
    p = _json(row[0], {}) if row else {}
    out = dict(DEFAULT_POLICY)
    if isinstance(p, dict):
        out.update(p)
    if own:
        c.close()
    return out


def set_policy(patch):
    """只允许 DEFAULT_POLICY 里的键；类型不合法直接拒绝。"""
    if not isinstance(patch, dict):
        raise ValueError("policy 必须是对象")
    cur = get_policy()
    for k, v in patch.items():
        if k not in DEFAULT_POLICY:
            continue
        default = DEFAULT_POLICY[k]
        if isinstance(default, bool):
            v = bool(v)
        elif isinstance(default, int):
            try:
                v = int(v)
            except Exception:
                raise ValueError("%s 必须是整数" % k)
            if v < 0:
                raise ValueError("%s 不能为负" % k)
        elif isinstance(default, list):
            if not isinstance(v, list):
                raise ValueError("%s 必须是数组" % k)
            v = [str(x).strip()[:40] for x in v if str(x).strip()][:40]
        cur[k] = v
    c = db()
    try:
        c.execute("INSERT INTO ai_bot_config(key,value,updated) VALUES('policy',?,?)"
                  " ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated=excluded.updated",
                  (json.dumps(cur, ensure_ascii=False), now()))
        c.commit()
    finally:
        c.close()
    return cur


def state_get(key, default=None):
    c = db()
    try:
        row = c.execute("SELECT value FROM ai_bot_config WHERE key=?", (key,)).fetchone()
        return _json(row[0], default) if row else default
    finally:
        c.close()


def state_set(key, value):
    c = db()
    try:
        c.execute("INSERT INTO ai_bot_config(key,value,updated) VALUES(?,?,?)"
                  " ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated=excluded.updated",
                  (key, json.dumps(value, ensure_ascii=False), now()))
        c.commit()
    finally:
        c.close()


def config_get(key, default=None):
    c = db()
    try:
        row = c.execute("SELECT value FROM ai_bot_config WHERE key=?", (key,)).fetchone()
        return row[0] if row else default
    finally:
        c.close()


# ---------------- 动作日志 --------------
def action_log(kind, target_id="", detail="", status="done", result="",
               dedupe_key=None, c=None):
    own = c is None
    c = _conn(c)
    aid = uuid.uuid4().hex
    try:
        cur = c.execute(
            "INSERT OR IGNORE INTO ai_bot_actions(id,kind,target_id,dedupe_key,detail,status,result,created,updated)"
            " VALUES(?,?,?,?,?,?,?,?,?)",
            (aid, kind[:48], str(target_id or "")[:80], dedupe_key, str(detail or "")[:600],
             status[:20], str(result or "")[:800], now(), now()))
        if own:
            c.commit()
        return aid if cur.rowcount else None
    except Exception:
        if own:
            c.rollback()
        return None
    finally:
        if own:
            c.close()


def action_update(action_id, status, result=""):
    c = db()
    try:
        c.execute("UPDATE ai_bot_actions SET status=?,result=?,updated=? WHERE id=?",
                  (status, str(result or "")[:800], now(), action_id))
        c.commit()
    finally:
        c.close()


def count_today(kinds):
    """按自然日统计（本地时区 00:00 起），和后台显示的「今天」一致。"""
    lt = time.localtime()
    since = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))
    c = db()
    try:
        q = " OR ".join(["kind LIKE ?" for _ in kinds])
        args = [k + "%" for k in kinds]
        return c.execute(
            "SELECT COUNT(DISTINCT CASE WHEN target_id<>'' THEN target_id ELSE id END)"
            " FROM ai_bot_actions WHERE (" + q +
            ") AND status IN ('done','pending_review') AND created>=?",
            args + [since]).fetchone()[0]
    finally:
        c.close()


def on_post_reviewed(c, post_id, approved):
    """管理员审核 AI 帖子/视频后，把待审记录改成真实结果。"""
    status = "done" if approved else "rejected"
    result = "审核通过，已公开" if approved else "管理员拒绝"
    c.execute("UPDATE ai_bot_actions SET status=?,result=?,updated=?"
              " WHERE target_id=? AND status='pending_review'"
              " AND kind IN ('post.pending','video.pending','post.auto','video.auto')",
              (status, result, now(), post_id))
    if approved:
        action_log("post.published", post_id, "管理员审核通过", "done",
                   "已公开", dedupe_key="publish:approved:%s" % post_id, c=c)


def on_app_reviewed(c, app_id, approved):
    status = "done" if approved else "rejected"
    result = "审核通过，已上架" if approved else "管理员拒绝"
    c.execute("UPDATE ai_bot_actions SET status=?,result=?,updated=?"
              " WHERE target_id=? AND status='pending_review'"
              " AND kind IN ('app.pending','app.auto')",
              (status, result, now(), app_id))
    if approved:
        action_log("app.published", app_id, "管理员审核通过", "done",
                   "已上架", dedupe_key="app:approved:%s" % app_id, c=c)


# ---------------- 官方账号 --------------
def bot_user(c=None):
    own = c is None
    c = _conn(c)
    row = c.execute("SELECT id,name,avatar,signature,gender,age,city,title,verified,"
                    "verified_label,is_ai,created FROM users WHERE id=?", (BOT_ID,)).fetchone()
    if own:
        c.close()
    return row_dict(row) if row else {}


def update_profile(fields, source="dm"):
    """AI 自改资料。锁定：名字/头像/密码/邮箱/性别/账号 ID/认证/会员/封禁。"""
    c = db()
    try:
        sets, args, desc = [], [], []
        for key, raw in (fields or {}).items():
            if key not in PROFILE_FIELDS:
                continue
            col, limit = PROFILE_FIELDS[key]
            if key == "age":
                try:
                    val = max(0, min(120, int(raw)))
                except Exception:
                    continue
            elif key == "gender":
                val = str(raw or "").strip()[:8]
                if val not in ("男", "女", "其他", ""):
                    continue
            elif key == "background_image":
                val = str(raw or "").strip()
                if not re.match(r"^/community/api/media/(community_img_|community_banner_)[\w\-\.]+$", val):
                    continue
                name = val.rsplit("/", 1)[-1]
                if not os.path.exists(os.path.join(FILES_DIR, name)):
                    continue
            else:
                val = str(raw or "").strip()[:limit]
            sets.append(col + "=?")
            args.append(val)
            desc.append("%s=%s" % (key, str(val)[:40]))
        if not sets:
            return False, "没有可修改的字段"
        c.execute("UPDATE users SET " + ",".join(sets) + " WHERE id=?", args + [BOT_ID])
        action_log("profile.update", BOT_ID, "；".join(desc), "done",
                   "资料已更新", c=c)
        c.commit()
        return True, "资料已更新"
    finally:
        c.close()


# ---------------- 关注 / 回关 --------------
def follow_back(user_id, c=None):
    own = c is None
    c = _conn(c)
    try:
        if not user_id or user_id == BOT_ID:
            return False
        row = c.execute("SELECT id,name,banned FROM users WHERE id=?", (user_id,)).fetchone()
        if not row or int(row[2] or 0):
            return False
        exists = c.execute("SELECT 1 FROM follows WHERE follower_id=? AND following_id=?",
                           (BOT_ID, user_id)).fetchone()
        if exists:
            return False
        c.execute("INSERT OR IGNORE INTO follows(follower_id,following_id,created) VALUES(?,?,?)",
                  (BOT_ID, user_id, now()))
        try:
            notify(c, user_id, "community_interact", "流小萤关注了你",
                   "你关注了流小萤，它回关了你。现在可以私信它。",
                   from_uid=BOT_ID, from_name=BOT_NAME)
        except Exception:
            pass
        action_log("follow.back", user_id, "回关 %s" % (row[1] or user_id), "done",
                   "已回关", dedupe_key="follow:%s" % user_id, c=c)
        if own:
            c.commit()
        return True
    finally:
        if own:
            c.close()


def followback_scan(limit=50):
    c = db()
    try:
        rows = c.execute(
            "SELECT f.follower_id,u.name FROM follows f JOIN users u ON u.id=f.follower_id"
            " WHERE f.following_id=? AND u.banned=0"
            " AND NOT EXISTS (SELECT 1 FROM follows b WHERE b.follower_id=? AND b.following_id=f.follower_id)"
            " ORDER BY f.created ASC LIMIT ?",
            (BOT_ID, BOT_ID, limit)).fetchall()
        done = 0
        for r in rows:
            if follow_back(r[0], c=c):
                done += 1
        c.commit()
        return done
    finally:
        c.close()


# ---------------- 帖子 / 视频 --------------
def insert_post(ptype, content, images=None, video="", cover="", duration=0,
                board_id="", topics=None, source="auto"):
    c = db()
    try:
        content = (content or "").strip()[:2000]
        if not content and not video:
            raise ValueError("内容不能为空")
        hits = [h["word"] for h in check_sensitive(c, content) if h["level"] == 0]
        if hits:
            raise ValueError("敏感词：" + "、".join(hits[:5]))
        from common import ensure_topics, bump_board_count
        topics = [str(x).strip()[:30] for x in (topics or []) if str(x).strip()][:10]
        ensure_topics(c, topics)
        pid = uuid.uuid4().hex
        approved = bool(get_policy(c).get("auto_publish"))
        c.execute(
            "INSERT INTO community_posts(id,user_id,type,content,images,music,audio_volume,"
            "music_volume,video,cover,duration,board_id,tag,topic,mentions,poll,created,audit_status)"
            " VALUES(?,?,?,?,?, '',100,50,?,?,?,?, '',?, '[]', '',?,?)",
            (pid, BOT_ID, ptype, content, json.dumps(images or [], ensure_ascii=False),
             video, cover, duration, board_id, json.dumps(topics, ensure_ascii=False),
             now(), 1 if approved else 0))
        if approved:
            c.execute("UPDATE community_posts SET audited_at=? WHERE id=?", (now(), pid))
        if board_id:
            bump_board_count(c, board_id, 1)
        c.commit()
        kind = "video" if ptype == "video" else "post"
        action_log("%s.published" % kind if approved else "%s.pending" % kind, pid,
                   content[:160], "done" if approved else "pending_review",
                   "自动发布，待抽查" if approved else "等待管理员审核",
                   dedupe_key="publish:%s" % pid, c=c)
        c.commit()
        return pid
    finally:
        c.close()


def insert_video(mp4_path, cover_name, duration):
    c = db()
    try:
        vid = os.path.basename(mp4_path)[:-4]
        c.execute("INSERT OR REPLACE INTO community_videos"
                  "(id,user_id,duration,status,cover,error,created,updated)"
                  " VALUES(?,?,?,?,?, '',?,?)",
                  (vid, BOT_ID, float(duration or 0), "done", cover_name, now(), now()))
        c.commit()
        return vid
    finally:
        c.close()


def recent_posts(limit=30, days=4):
    c = db()
    try:
        since = now() - days * 86400
        rows = c.execute(
            "SELECT * FROM community_posts WHERE status=1 AND audit_status=1 AND taken_down=0"
            " AND created>=? AND user_id<>? ORDER BY created DESC LIMIT ?",
            (since, BOT_ID, limit)).fetchall()
        return [row_dict(r) for r in rows]
    finally:
        c.close()


def recent_apps(limit=20, days=45):
    c = db()
    try:
        since = now() - days * 86400
        rows = c.execute(
            "SELECT * FROM community_apps WHERE status=2 AND created>=? ORDER BY created DESC LIMIT ?",
            (since, limit)).fetchall()
        return [row_dict(r) for r in rows]
    finally:
        c.close()


def get_post(post_id):
    c = db()
    try:
        row = c.execute("SELECT * FROM community_posts WHERE id=?", (post_id,)).fetchone()
        return row_dict(row) if row else None
    finally:
        c.close()


def get_app(app_id):
    c = db()
    try:
        row = c.execute("SELECT * FROM community_apps WHERE id=?", (app_id,)).fetchone()
        return row_dict(row) if row else None
    finally:
        c.close()


def resolve_post_target(target):
    """支持帖子 ID、/post/{id} 链接、帖子正文片段。返回 (post_id, post_row)。"""
    if not target:
        return None, None
    t = str(target).strip()
    m = re.search(r"/post/([A-Za-z0-9_-]{16,64})", t)
    if m:
        t = m.group(1)
    if re.match(r"^[A-Za-z0-9_-]{16,64}$", t):
        row = get_post(t)
        if row:
            return t, row
    if len(t) >= 2:
        c = db()
        try:
            row = c.execute(
                "SELECT * FROM community_posts WHERE status=1 AND audit_status=1"
                " AND taken_down=0 AND (content LIKE ? OR id LIKE ?) ORDER BY created DESC LIMIT 1",
                ("%" + t[:40] + "%", t)).fetchone()
            if row:
                return row["id"], row_dict(row)
        finally:
            c.close()
    return None, None


def resolve_app_target(target):
    if not target:
        return None, None
    t = str(target).strip()
    m = re.search(r"/apps?/([A-Za-z0-9_-]{12,64})", t)
    if m:
        t = m.group(1)
    row = get_app(t)
    if row:
        return t, row
    c = db()
    try:
        row = c.execute("SELECT * FROM community_apps WHERE status=2 AND name LIKE ?"
                        " ORDER BY created DESC LIMIT 1", ("%" + t[:40] + "%",)).fetchone()
        if row:
            return row["id"], row_dict(row)
    finally:
        c.close()
    return None, None


def _media_path(name_or_url):
    if not name_or_url:
        return ""
    name = str(name_or_url).strip()
    if name.startswith("/community/api/media/"):
        name = name[len("/community/api/media/"):]
    if ".." in name or "/" in name:
        return ""
    p = os.path.join(FILES_DIR, name)
    return p if os.path.exists(p) else ""


def post_media_paths(post, max_images=3):
    """帖子配图/视频帧，供视觉模型看内容。"""
    if not post:
        return []
    out = []
    for u in (_json(post.get("images"), []) or [])[:max_images]:
        p = _media_path(u)
        if p:
            out.append(p)
    if post.get("type") == "video" and post.get("video"):
        vname = post["video"]
        if "." not in vname:
            vname += ".mp4"
        vp = _media_path(vname)
        if vp:
            frames = MEDIA.extract_frames(vp, 3)
            out.extend(frames)
    return out[:4]


def post_context(post):
    author = user_mini(post.get("user_id", ""))
    return {
        "id": post.get("id"), "type": post.get("type"),
        "content": post.get("content", "")[:500],
        "author": (author or {}).get("name", ""),
        "topics": _json(post.get("topic"), []),
        "images": _json(post.get("images"), []),
    }


# ---------------- 内容互动 --------------
def like_post(post_id, source="auto", peer=""):
    c = db()
    try:
        row = c.execute("SELECT * FROM community_posts WHERE id=? AND status=1 AND audit_status=1 AND taken_down=0",
                        (post_id,)).fetchone()
        if not row:
            return "帖子不存在或不可互动"
        if row["user_id"] == BOT_ID:
            return "不点赞自己的帖子"
        exists = c.execute("SELECT 1 FROM community_post_likes WHERE user_id=? AND post_id=?",
                           (BOT_ID, post_id)).fetchone()
        if exists:
            return "已经点过赞"
        c.execute("INSERT INTO community_post_likes(user_id,post_id,created) VALUES(?,?,?)",
                  (BOT_ID, post_id, now()))
        c.execute("UPDATE community_posts SET like_count=like_count+1 WHERE id=?", (post_id,))
        d = row_dict(row)
        try:
            notify(c, d["user_id"], "community_like", "收到新点赞",
                   "%s 赞了你的%s" % (BOT_NAME, "视频" if d.get("type") == "video" else "帖子"),
                   from_uid=BOT_ID, from_name=BOT_NAME,
                   extra={"postId": post_id})
            gain = 3 if d.get("type") == "video" else 2
            add_exp(c, d["user_id"], gain)
        except Exception:
            pass
        c.commit()
        key = None if peer else "like:post:%s" % post_id
        action_log("post.like", post_id, "点赞帖子", "done", "已点赞",
                   dedupe_key=key, c=c)
        c.commit()
        return "已点赞"
    finally:
        c.close()


def comment_post(post_id, content, source="auto", peer=""):
    c = db()
    try:
        row = c.execute("SELECT * FROM community_posts WHERE id=? AND status=1 AND audit_status=1 AND taken_down=0",
                        (post_id,)).fetchone()
        if not row:
            return "帖子不存在或不可评论"
        if row["user_id"] == BOT_ID:
            return "不评论自己的帖子"
        author = row["user_id"]
        prefs = c.execute("SELECT comment_perm FROM community_user_prefs WHERE user_id=?",
                          (author,)).fetchone()
        perm = prefs[0] if prefs else 0
        if perm == 2:
            return "作者已关闭评论"
        if perm == 1 and not c.execute(
                "SELECT 1 FROM follows WHERE follower_id=? AND following_id=?",
                (BOT_ID, author)).fetchone():
            return "作者仅允许关注者评论"
        try:
            from common import is_blocked
            if is_blocked(c, author, BOT_ID):
                return "作者已屏蔽我，无法评论"
        except Exception:
            pass
        content = (content or "").strip()[:500]
        if not content:
            return "评论不能为空"
        if any(h["level"] == 0 for h in check_sensitive(c, content)):
            return "评论包含敏感词"
        exists = c.execute("SELECT 1 FROM community_post_comments WHERE post_id=? AND user_id=?",
                           (post_id, BOT_ID)).fetchone()
        if exists:
            return "已经评论过"
        cid = uuid.uuid4().hex
        c.execute("INSERT INTO community_post_comments(id,post_id,user_id,content,images,sticker,created)"
                  " VALUES(?,?,?,?, '[]','',?)", (cid, post_id, BOT_ID, content, now()))
        c.execute("UPDATE community_posts SET comment_count=comment_count+1 WHERE id=?", (post_id,))
        d = row_dict(row)
        try:
            notify(c, d["user_id"], "community_comment", "收到新评论",
                   "%s 评论了你的帖子：%s" % (BOT_NAME, content[:60]),
                   from_uid=BOT_ID, from_name=BOT_NAME,
                   extra={"postId": post_id, "commentId": cid})
            add_exp(c, d["user_id"], 2)
        except Exception:
            pass
        c.commit()
        key = None if peer else "comment:post:%s" % post_id
        action_log("post.comment", post_id, content[:160], "done", "已评论",
                   dedupe_key=key, c=c)
        c.commit()
        return "已评论"
    finally:
        c.close()


def favorite_post(post_id, source="auto"):
    c = db()
    try:
        row = c.execute("SELECT 1 FROM community_posts WHERE id=? AND status=1 AND audit_status=1 AND taken_down=0",
                        (post_id,)).fetchone()
        if not row:
            return "帖子不存在"
        if c.execute("SELECT 1 FROM community_favorites WHERE user_id=? AND post_id=? AND kind='fav'",
                     (BOT_ID, post_id)).fetchone():
            return "已经收藏"
        c.execute("INSERT OR IGNORE INTO community_favorites(user_id,post_id,kind,created)"
                  " VALUES(?,?, 'fav',?)", (BOT_ID, post_id, now()))
        c.commit()
        action_log("post.fav", post_id, "收藏帖子", "done", "已收藏",
                   dedupe_key="fav:post:%s" % post_id, c=c)
        c.commit()
        return "已收藏"
    finally:
        c.close()


def like_app(app_id, source="auto"):
    c = db()
    try:
        row = c.execute("SELECT * FROM community_apps WHERE id=? AND status=2", (app_id,)).fetchone()
        if not row:
            return "应用不存在或未上架"
        exists = c.execute("SELECT 1 FROM community_app_favorites WHERE user_id=? AND app_id=?",
                           (BOT_ID, app_id)).fetchone()
        if exists:
            return "已经收藏过"
        c.execute("INSERT INTO community_app_favorites(user_id,app_id,created) VALUES(?,?,?)",
                  (BOT_ID, app_id, now()))
        c.execute("UPDATE community_apps SET favorite_count=favorite_count+1 WHERE id=?", (app_id,))
        c.commit()
        action_log("app.fav", app_id, "收藏应用", "done", "已收藏",
                   dedupe_key="fav:app:%s" % app_id, c=c)
        c.commit()
        return "已收藏"
    finally:
        c.close()


def comment_app(app_id, content, source="auto"):
    c = db()
    try:
        row = c.execute("SELECT * FROM community_apps WHERE id=? AND status=2", (app_id,)).fetchone()
        if not row:
            return "应用不存在或未上架"
        content = (content or "").strip()[:600]
        if not content:
            return "评论不能为空"
        if any(h["level"] == 0 for h in check_sensitive(c, content)):
            return "评论包含敏感词"
        if c.execute("SELECT 1 FROM community_app_comments WHERE app_id=? AND user_id=?",
                     (app_id, BOT_ID)).fetchone():
            return "已经评论过"
        cid = uuid.uuid4().hex
        c.execute("INSERT INTO community_app_comments(id,app_id,user_id,parent_id,content,status,created)"
                  " VALUES(?,?,?, '', ?,1,?)", (cid, app_id, BOT_ID, content, now()))
        c.execute("UPDATE community_apps SET comment_count=comment_count+1 WHERE id=?", (app_id,))
        c.commit()
        action_log("app.comment", app_id, content[:160], "done", "已评论",
                   dedupe_key="comment:app:%s" % app_id, c=c)
        c.commit()
        return "已评论"
    finally:
        c.close()


# ---------------- 私信 --------------
def _mutual_follow(c, a, b):
    if not a or not b or a == b:
        return False
    return bool(c.execute("SELECT 1 FROM follows WHERE follower_id=? AND following_id=?",
                          (a, b)).fetchone() and
                c.execute("SELECT 1 FROM follows WHERE follower_id=? AND following_id=?",
                          (b, a)).fetchone())


def send_dm(peer, content, msg_type="text"):
    c = db()
    try:
        content = (content or "").strip()[:2000]
        if not content:
            return False
        if not _mutual_follow(c, BOT_ID, peer):
            # 对方关注了 AI 但 AI 还没回关时，先补回关再发。
            if not follow_back(peer, c=c):
                return False
            if not _mutual_follow(c, BOT_ID, peer):
                return False
        mid = uuid.uuid4().hex
        created = now()
        conv = "%s_%s" % (min(BOT_ID, peer), max(BOT_ID, peer))
        a, b = str(BOT_ID), str(peer)
        ua, ub = (a, b) if a <= b else (b, a)
        c.execute("INSERT INTO community_dm_messages(id,conv_id,sender_id,receiver_id,content,created,is_read,msg_type)"
                  " VALUES(?,?,?,?,?,?,0,?)",
                  (mid, conv, BOT_ID, peer, content, created, msg_type))
        if msg_type == "image":
            preview = "[表情]" if "emoji_official/liuying/" in content else "[图片]"
        elif msg_type == "video":
            preview = "[视频]"
        else:
            preview = content[:120]
        if str(BOT_ID) == ua:
            c.execute("INSERT INTO community_conversations(id,user_a,user_b,last_msg,last_type,last_time,unread_a,unread_b,created)"
                      " VALUES(?,?,?,?,?,?,0,1,?) ON CONFLICT(id) DO UPDATE SET"
                      " last_msg=excluded.last_msg,last_type=excluded.last_type,"
                      " last_time=excluded.last_time,unread_b=unread_b+1",
                      (conv, ua, ub, preview, msg_type, created, created))
        else:
            c.execute("INSERT INTO community_conversations(id,user_a,user_b,last_msg,last_type,last_time,unread_a,unread_b,created)"
                      " VALUES(?,?,?,?,?,?,1,0,?) ON CONFLICT(id) DO UPDATE SET"
                      " last_msg=excluded.last_msg,last_type=excluded.last_type,"
                      " last_time=excluded.last_time,unread_a=unread_a+1",
                      (conv, ua, ub, preview, msg_type, created, created))
        c.commit()
        try:
            from handlers import ws as H_WS
            H_WS.ws_push(peer, {"kind": "dm", "dm": {
                "id": mid,
                "convId": conv, "from": {"id": BOT_ID, "name": BOT_NAME, "avatar": bot_user(c).get("avatar", "")},
                "content": content, "msgType": msg_type, "created": created},
                "unread": c.execute("SELECT COUNT(*) FROM community_dm_messages WHERE receiver_id=? AND is_read=0",
                                    (peer,)).fetchone()[0]})
        except Exception:
            pass
        return True
    finally:
        c.close()


def dm_history(peer, limit=12):
    c = db()
    try:
        conv = "%s_%s" % (min(BOT_ID, peer), max(BOT_ID, peer))
        rows = c.execute("SELECT * FROM community_dm_messages WHERE conv_id=? ORDER BY created DESC LIMIT ?",
                        (conv, limit)).fetchall()
        out = []
        for r in reversed(rows):
            content = r["content"] or ""
            if (r["sender_id"] == BOT_ID and (r["msg_type"] or "text") == "image"
                    and "emoji_official/liuying/" in content):
                content = "[表情]"
            out.append({"role": "assistant" if r["sender_id"] == BOT_ID else "user",
                        "content": content})
        return out
    finally:
        c.close()


def conv_state(peer):
    c = db()
    try:
        row = c.execute("SELECT state_json FROM ai_bot_conversations WHERE peer_id=?", (peer,)).fetchone()
        return _json(row[0], {}) if row else {}
    finally:
        c.close()


def conv_state_set(peer, state, last_msg_id=""):
    c = db()
    try:
        c.execute("INSERT INTO ai_bot_conversations(peer_id,state_json,last_msg_id,last_msg_at,created,updated)"
                  " VALUES(?,?,?,?,?,?) ON CONFLICT(peer_id) DO UPDATE SET"
                  " state_json=excluded.state_json,last_msg_id=excluded.last_msg_id,"
                  " last_msg_at=excluded.last_msg_at,updated=excluded.updated",
                  (peer, json.dumps(state, ensure_ascii=False), last_msg_id, now(), now(), now()))
        c.commit()
    finally:
        c.close()


def admin_stats():
    c = db()
    try:
        p = get_policy(c)
        bot = bot_user(c)
        counts = {}
        for k, sql in (
            ("pendingPosts", "SELECT COUNT(*) FROM community_posts WHERE user_id=? AND audit_status=0"),
            ("approvedPosts", "SELECT COUNT(*) FROM community_posts WHERE user_id=? AND audit_status=1"),
            ("pendingApps", "SELECT COUNT(*) FROM community_apps WHERE submitter_id=? AND status=1"),
            ("approvedApps", "SELECT COUNT(*) FROM community_apps WHERE submitter_id=? AND status=2"),
            ("followers", "SELECT COUNT(*) FROM follows WHERE following_id=?"),
            ("following", "SELECT COUNT(*) FROM follows WHERE follower_id=?"),
        ):
            counts[k] = c.execute(sql, (BOT_ID,)).fetchone()[0]
        for k in ("post.like", "post.comment", "post.fav", "app.fav", "app.comment",
                  "follow.back", "post.pending", "video.pending", "app.pending"):
            counts[k] = c.execute("SELECT COUNT(*) FROM ai_bot_actions WHERE kind=?", (k,)).fetchone()[0]
        actions = [row_dict(r) for r in c.execute(
            "SELECT * FROM ai_bot_actions ORDER BY created DESC LIMIT 20").fetchall()]
        try:
            import ai_bot_schedule as SCHED
            schedule = SCHED.describe()
        except Exception:
            schedule = {}
        return {"bot": bot, "policy": p, "counts": counts, "recent": actions,
                "schedule": schedule,
                "workerHeartbeat": float(state_get("worker_heartbeat", 0) or 0),
                "workerStartedAt": float(state_get("worker_started_at", 0) or 0)}
    finally:
        c.close()
