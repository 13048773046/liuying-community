# -*- coding: utf-8 -*-
"""流萤社区 · 内容域接口：发帖/发视频/详情/评论/点赞/分享/投票/编辑/草稿/收藏/稍后看。

审核状态机：发布→待审(0)→后台审核→通过(1)进信息流 / 拒绝(2)通知作者；
编辑后回待审(0)；下架(taken_down)后不进信息流。
"""
import os
import re
import json
import time
import uuid
import sqlite3
import urllib.parse
import urllib.request

from common import (db, rate_limit, resolve_token, public_user, user_mini,
                    decorate_post, decorate_comment, notify, official_msg,
                    add_exp, EXP_RULES, parse_mentions, parse_topics,
                    ensure_topics, check_sensitive, task_progress,
                    is_blocked, blocked_by, row_dict, client_ip, record_behavior,
                    normalize_attachments, bump_board_count, MAX_ATTACHMENTS)
from core.settings import settings
from search_personalized import rank_profile_posts

MAX_CONTENT = 2000
MAX_IMAGES = 3
MAX_TOPIC = 10


def _behavior_meta(d):
    """行为事件快照：帖子被删/改版后，个性化画像仍能读到当时的板块与话题。"""
    topics = []
    try:
        raw = d.get("topic") or "[]"
        topics = json.loads(raw) if isinstance(raw, str) else list(raw)
    except Exception:
        topics = []
    return {"boardId": d.get("board_id") or "", "topics": topics[:10],
            "authorId": d.get("user_id") or "", "type": d.get("type") or ""}


def _uid(c, handler):
    return resolve_token(c, handler.headers.get("Authorization", ""))


def _parse_body(h):
    """尝试 JSON；失败尝试 multipart。返回 dict。"""
    body = h._json_body()
    if body is None:
        body = {}
    return body


def _music_field(raw):
    """配乐既能是对象也能是 JSON 字符串；无有效 url 视为无配乐。"""
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except Exception:
            return None
    if not isinstance(raw, dict):
        return None
    if not isinstance(raw.get("url"), str) or not raw["url"].strip():
        return None
    return raw


def _volume_field(raw, default):
    try:
        return max(0, min(100, int(raw)))
    except Exception:
        return default


def _audit_decision(c, uid, ptype, images, video, hits):
    """发布审核策略：信任用户纯文本自动通过，媒体/新用户/敏感词转人工。

    信任用户 = 管理员，或注册满 7 天、等级 ≥ 2、未被封禁的老用户。
    level=0 敏感词已在调用方直接拦截；level=1 一律转人工。
    """
    if any(h.get("level") == 1 for h in hits):
        return 0, "命中敏感词，转人工审核"
    row = c.execute("SELECT created,banned FROM users WHERE id=?", (uid,)).fetchone()
    if not row or row[1]:
        return 0, ""
    is_admin = bool(c.execute(
        "SELECT 1 FROM community_admins WHERE user_id=?", (uid,)).fetchone())
    if is_admin:
        return 1, ""
    exp = c.execute("SELECT level FROM community_exp WHERE user_id=?", (uid,)).fetchone()
    level = (exp[0] if exp else 0) or 0
    age = time.time() - (row[0] or 0)
    trusted = age >= 7 * 86400 and level >= 2
    if not trusted:
        return 0, ""
    if video or ptype == "video" or images:
        return 0, "媒体内容需人工审核"
    return 1, ""


def _post_created(c, uid, ptype, content, images, video, cover, duration,
                 board_id, topic_names, mention_list, poll=None,
                 music=None, audio_volume=100, music_volume=50, attachments=None):
    """公共创建逻辑：落库 + 话题 + @ 通知 + 敏感词拦截/转审 + 经验 + 任务。"""
    now = time.time()
    pid = uuid.uuid4().hex
    attachments = attachments or []
    # 敏感词：level=0 拦截；level=1 转人工待审
    hits = check_sensitive(c, content)
    block_hits = [h["word"] for h in hits if h["level"] == 0]
    if block_hits:
        return None, "内容包含敏感词：" + "、".join(block_hits[:5])
    audit_status, audit_reason = _audit_decision(
        c, uid, ptype, images, video, hits)
    # 话题入库
    ensure_topics(c, topic_names)
    c.execute(
        """INSERT INTO community_posts(id,user_id,type,content,images,music,
           audio_volume,music_volume,video,cover,duration,board_id,tag,topic,
           mentions,poll,attachments,created,audit_status,audit_reason)
           VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (pid, uid, ptype, content, json.dumps(images, ensure_ascii=False),
         json.dumps(music, ensure_ascii=False) if music else "",
         audio_volume, music_volume, video, cover, duration, board_id, "",
         json.dumps(topic_names, ensure_ascii=False),
         json.dumps(mention_list, ensure_ascii=False),
         json.dumps(poll, ensure_ascii=False) if poll else "",
         json.dumps(attachments, ensure_ascii=False) if attachments else "[]",
         now, audit_status, audit_reason))
    if audit_status == 1:
        c.execute("UPDATE community_posts SET audited_at=? WHERE id=?", (now, pid))
    # 版块计数：子分类发帖同时汇总到父版块
    if board_id:
        bump_board_count(c, board_id, 1)
    # 经验
    gain = EXP_RULES.get({
        "text": "post_text", "video": "post_video", "poll": "post_poll"
    }.get(ptype, "post_text"), 10)
    _, _, _, leveled = add_exp(c, uid, gain)
    # 新手任务
    task_progress(c, uid, "t_first_post", 1)
    if ptype == "video":
        task_progress(c, uid, "t_first_video", 1)
    # @ 通知
    for m in mention_list:
        if m["id"] != uid:
            notify(c, m["id"], "community_mention",
                   "有人 @ 了你", "%s 在帖子中提到了你" % (user_mini(c, uid)["name"] or "用户"),
                   from_uid=uid, from_name=user_mini(c, uid)["name"],
                   extra={"postId": pid})
    return pid, None


# ---------------- 发帖 / 发视频 / 投票帖 ----------------
def _handle_post(self, c, u, api, method):
    if api != "/post" or method != "POST":
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录或登录已过期")
        return True
    body = _parse_body(self)
    content = (body.get("content") or "").strip()
    if not content and not body.get("video"):
        self._err(400, "内容不能为空")
        return True
    if len(content) > MAX_CONTENT:
        self._err(400, "内容过长（≤%d 字）" % MAX_CONTENT)
        return True
    if not rate_limit(self, "post"):
        self._err(429, "发帖过于频繁，请稍后再试")
        return True
    images = body.get("images") or []
    if not isinstance(images, list):
        images = []
    images = [x for x in images if isinstance(x, str)]
    if len(images) > MAX_IMAGES:
        self._err(400, "图片最多 %d 张" % MAX_IMAGES)
        return True
    images = images[:MAX_IMAGES]
    board_id = (body.get("boardId") or "").strip()
    # 话题与 @：客户端已解析优先，服务端兜底
    topic_names = body.get("topic") or parse_topics(content)
    mention_list = body.get("mentions") or parse_mentions(c, content)
    if not isinstance(topic_names, list):
        topic_names = parse_topics(content)
    if not isinstance(mention_list, list):
        mention_list = parse_mentions(c, content)
    mention_list = [{"id": m["id"], "name": m.get("name", "")} for m in mention_list
                    if isinstance(m, dict) and m.get("id")]
    # 投票帖
    poll = None
    if body.get("poll"):
        p = body["poll"]
        question = (p.get("question") or "").strip()[:60]
        options = [str(x).strip()[:40] for x in (p.get("options") or []) if str(x).strip()]
        if not question or len(options) < 2:
            self._err(400, "投票帖需要问题与至少 2 个选项")
            return True
        options = options[:5]
        poll = {"question": question, "options": options,
                "votes": [0] * len(options),
                "endAt": int(p.get("endAt") or 0), "multi": 1 if p.get("multi") else 0}
    music = _music_field(body.get("music"))
    audio_volume = _volume_field(body.get("audioVolume"), 100)
    music_volume = _volume_field(body.get("musicVolume"), 50)
    attachments, attach_err = normalize_attachments(uid, body.get("attachments"))
    if attach_err:
        self._err(400, attach_err)
        return True
    pid, err = _post_created(c, uid, "poll" if poll else "text", content, images,
                             "", "", 0, board_id, topic_names, mention_list, poll,
                             music, audio_volume, music_volume, attachments)
    if err:
        self._err(400, err)
        return True
    row = c.execute("SELECT * FROM community_posts WHERE id=?", (pid,)).fetchone()
    c.commit()
    self._ok({"post": decorate_post(c, row, uid)})
    return True


def _handle_video_post(self, c, u, api, method):
    if api != "/video/post" or method != "POST":
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录或登录已过期")
        return True
    body = _parse_body(self)
    video = (body.get("video") or "").strip()
    if not video or not re.match(r"^community_video_[\w\-]+$", video):
        self._err(400, "请先上传视频")
        return True
    vrow = c.execute("SELECT id FROM community_videos WHERE id=? AND user_id=?",
                     (video, uid)).fetchone()
    if not vrow:
        self._err(400, "视频不存在或不属于当前账号")
        return True
    if not rate_limit(self, "video"):
        self._err(429, "发视频过于频繁，请稍后再试")
        return True
    content = (body.get("content") or "").strip()
    if len(content) > MAX_CONTENT:
        self._err(400, "文案过长（≤%d 字）" % MAX_CONTENT)
        return True
    cover = (body.get("cover") or "").strip()
    duration = float(body.get("duration") or 0)
    board_id = (body.get("boardId") or "").strip()
    topic_names = body.get("topic") or parse_topics(content)
    mention_list = body.get("mentions") or parse_mentions(c, content)
    if not isinstance(topic_names, list):
        topic_names = parse_topics(content)
    if not isinstance(mention_list, list):
        mention_list = parse_mentions(c, content)
    mention_list = [{"id": m["id"], "name": m.get("name", "")} for m in mention_list
                    if isinstance(m, dict) and m.get("id")]
    music = _music_field(body.get("music"))
    audio_volume = _volume_field(body.get("audioVolume"), 100)
    music_volume = _volume_field(body.get("musicVolume"), 50)
    attachments, attach_err = normalize_attachments(uid, body.get("attachments"))
    if attach_err:
        self._err(400, attach_err)
        return True
    pid, err = _post_created(c, uid, "video", content, [], video, cover, duration,
                             board_id, topic_names, mention_list, None,
                             music, audio_volume, music_volume, attachments)
    if err:
        self._err(400, err)
        return True
    row = c.execute("SELECT * FROM community_posts WHERE id=?", (pid,)).fetchone()
    c.commit()
    self._ok({"post": decorate_post(c, row, uid)})
    return True


# ---------------- 详情 / 列表 ----------------
def _get_post(c, uid, pid, viewer):
    row = c.execute("SELECT * FROM community_posts WHERE id=? AND status=1", (pid,)).fetchone()
    if not row:
        return None, "帖子不存在"
    d = row_dict(row)
    # 可见性：他人只能看 通过+未下架；作者/管理员可见全部
    is_author = d["user_id"] == viewer
    is_admin = False
    if viewer:
        is_admin = bool(c.execute("SELECT 1 FROM community_admins WHERE user_id=?", (viewer,)).fetchone())
    if not is_author and not is_admin:
        if d.get("audit_status", 0) != 1:
            return None, "内容审核中或未通过"
        if d.get("taken_down", 0):
            return None, "内容已下架"
    return row, None


def _interactive_ok(d):
    """互动入口只对已通过且未下架的帖子开放，审核中/拒绝/下架一律按不存在处理。"""
    return d.get("audit_status", 0) == 1 and not d.get("taken_down", 0)


def _handle_post_detail(self, c, u, api, method):
    m = re.match(r"^/post/([\w\-]+)$", api)
    if not m:
        return False
    pid = m.group(1)
    viewer = _uid(c, self)
    row, err = _get_post(c, None, pid, viewer)
    if err:
        self._err(404, err)
        return True
    if viewer:
        record_behavior(c, viewer, pid, "view", 1.0, _behavior_meta(row_dict(row)))
    c.commit()
    self._ok({"post": decorate_post(c, row, viewer)})
    return True


def _handle_user_posts(self, c, u, api, method):
    m = re.match(r"^/user/([\w\-]+)/posts$", api)
    if not m:
        return False
    target = m.group(1)
    query = urllib.parse.parse_qs(u.query)
    page = max(1, int((query.get("page") or ["1"])[0] or 1))
    size = min(50, max(1, int((query.get("size") or ["20"])[0] or 20)))
    ptype = (query.get("type") or [""])[0]
    personalized = (query.get("personalized") or [""])[0].lower() in ("1", "true", "yes")
    viewer = _uid(c, self)
    # 隐私：主页仅关注可见
    prefs = c.execute("SELECT profile_visible FROM community_user_prefs WHERE user_id=?",
                      (target,)).fetchone()
    if prefs and prefs[0] == 1 and viewer != target:
        if not (viewer and c.execute("SELECT 1 FROM follows WHERE follower_id=? AND following_id=?",
                                     (viewer, target)).fetchone()):
            self._err(403, "该用户主页仅关注者可见")
            return True
    scoped = personalized and page == 1 and viewer and viewer != target
    sql = "SELECT * FROM community_posts WHERE user_id=? AND status=1"
    args = [target]
    if ptype:
        sql += " AND type=?"
        args.append(ptype)
    if viewer == target:
        # 作者看全部（含待审/拒绝/下架）
        sql += " ORDER BY created DESC LIMIT ? OFFSET ?"
    else:
        sql += " AND audit_status=1 AND taken_down=0 ORDER BY created DESC LIMIT ? OFFSET ?"
    if scoped:
        candidate_limit = min(80, max(size * 3, size))
        sql = sql.replace("ORDER BY created DESC LIMIT ? OFFSET ?",
                          "ORDER BY created DESC LIMIT ?")
        rows = c.execute(sql, args + [candidate_limit]).fetchall()
        ranked = rank_profile_posts(c, viewer, target, rows, size)
        items = []
        for row, reason in ranked:
            item = decorate_post(c, row, viewer)
            item["reason"] = reason
            items.append(item)
        has_more = len(rows) >= candidate_limit
    else:
        rows = c.execute(sql, args + [size, (page - 1) * size]).fetchall()
        items = [decorate_post(c, r, viewer) for r in rows]
        has_more = len(rows) == size
    c.commit()
    self._ok({"list": items, "page": page, "size": size, "hasMore": has_more,
              "personalized": scoped})
    return True


# ---------------- 点赞 / 分享 / 评论 / 投票 ----------------
def _handle_like(self, c, u, api, method):
    m = re.match(r"^/post/([\w\-]+)/like$", api)
    if not m:
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    pid = m.group(1)
    row = c.execute("SELECT * FROM community_posts WHERE id=? AND status=1", (pid,)).fetchone()
    if not row:
        self._err(404, "帖子不存在")
        return True
    d = row_dict(row)
    if not _interactive_ok(d):
        self._err(404, "帖子不存在")
        return True
    if method == "DELETE":
        exists = c.execute(
            "SELECT 1 FROM community_post_likes WHERE user_id=? AND post_id=?",
            (uid, pid)).fetchone()
        if not exists:
            c.commit()
            self._ok({"liked": False, "likeCount": d["like_count"]})
            return True
        c.execute("DELETE FROM community_post_likes WHERE user_id=? AND post_id=?", (uid, pid))
        c.execute("UPDATE community_posts SET like_count="
                  "CASE WHEN like_count>0 THEN like_count-1 ELSE 0 END WHERE id=?", (pid,))
        record_behavior(c, uid, pid, "unlike", -1.0, _behavior_meta(d))
        c.commit()
        count = c.execute("SELECT like_count FROM community_posts WHERE id=?", (pid,)).fetchone()[0]
        self._ok({"liked": False, "likeCount": count})
        return True
    if not rate_limit(self, "like"):
        self._err(429, "操作过于频繁")
        return True
    exists = c.execute("SELECT 1 FROM community_post_likes WHERE user_id=? AND post_id=?",
                       (uid, pid)).fetchone()
    if exists:
        c.commit()
        self._ok({"liked": True, "likeCount": d["like_count"]})
        return True
    c.execute("INSERT INTO community_post_likes(user_id,post_id,created) VALUES(?,?,?)",
              (uid, pid, time.time()))
    c.execute("UPDATE community_posts SET like_count=like_count+1 WHERE id=?", (pid,))
    record_behavior(c, uid, pid, "like", 4.0, _behavior_meta(d))
    # 经验：作者被赞（视频 3 / 其他 2）；点赞者 +1（日上限由调用侧控制）
    author = d["user_id"]
    if author != uid:
        gain = EXP_RULES["be_liked_video"] if d["type"] == "video" else EXP_RULES["be_liked_text"]
        add_exp(c, author, gain)
        notify(c, author, "community_like", "收到新点赞",
               "%s 赞了你的%s" % (user_mini(c, uid)["name"] or "用户",
                                 "视频" if d["type"] == "video" else "帖子"),
               from_uid=uid, from_name=user_mini(c, uid)["name"],
               extra={"postId": pid})
    add_exp(c, uid, EXP_RULES["like_other"])
    task_progress(c, uid, "t_first_like", 1)
    c.commit()
    self._ok({"liked": True, "likeCount": d["like_count"] + 1})
    return True


def _handle_share(self, c, u, api, method):
    m = re.match(r"^/post/([\w\-]+)/share$", api)
    if not m:
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    pid = m.group(1)
    row = c.execute("SELECT * FROM community_posts WHERE id=? AND status=1", (pid,)).fetchone()
    if not row:
        self._err(404, "帖子不存在")
        return True
    d = row_dict(row)
    if not _interactive_ok(d):
        self._err(404, "帖子不存在")
        return True
    if not rate_limit(self, "share"):
        self._err(429, "操作过于频繁")
        return True
    exists = c.execute("SELECT 1 FROM community_shares WHERE user_id=? AND post_id=?",
                       (uid, pid)).fetchone()
    if exists:
        c.commit()
        self._ok({"shared": True, "shareCount": d["share_count"]})
        return True
    c.execute("INSERT INTO community_shares(user_id,post_id,created) VALUES(?,?,?)",
              (uid, pid, time.time()))
    c.execute("UPDATE community_posts SET share_count=share_count+1 WHERE id=?", (pid,))
    record_behavior(c, uid, pid, "share", 5.0, _behavior_meta(d))
    if d["user_id"] != uid:
        add_exp(c, d["user_id"], EXP_RULES["be_shared"])
    add_exp(c, uid, 0)
    task_progress(c, uid, "t_first_share", 1)
    c.commit()
    self._ok({"shared": True, "shareCount": d["share_count"] + 1})
    return True


def _handle_comment(self, c, u, api, method):
    m = re.match(r"^/post/([\w\-]+)/comment$", api)
    if not m:
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    pid = m.group(1)
    row = c.execute("SELECT * FROM community_posts WHERE id=? AND status=1", (pid,)).fetchone()
    if not row:
        self._err(404, "帖子不存在")
        return True
    d = row_dict(row)
    if not _interactive_ok(d):
        self._err(404, "帖子不存在")
        return True
    # 评论权限
    prefs = c.execute("SELECT comment_perm FROM community_user_prefs WHERE user_id=?",
                      (d["user_id"],)).fetchone()
    perm = prefs[0] if prefs else 0
    if perm == 2 and d["user_id"] != uid:
        self._err(403, "作者已关闭评论")
        return True
    if perm == 1 and d["user_id"] != uid:
        if not c.execute("SELECT 1 FROM follows WHERE follower_id=? AND following_id=?",
                         (uid, d["user_id"])).fetchone():
            self._err(403, "仅关注者可评论")
            return True
    if is_blocked(c, d["user_id"], uid):
        self._err(403, "作者已屏蔽你，无法评论")
        return True
    body = _parse_body(self)
    content = (body.get("content") or "").strip()
    images = body.get("images") or []
    sticker = (body.get("sticker") or "").strip()
    if not isinstance(images, list):
        images = []
    images = [x for x in images if isinstance(x, str)][:1]
    # images 与 sticker 二选一（服务端强制）
    if images and sticker:
        self._err(400, "图片与表情包只能二选一")
        return True
    if not content and not images and not sticker:
        self._err(400, "评论内容不能为空")
        return True
    if len(content) > 500:
        self._err(400, "评论过长（≤500 字）")
        return True
    if not rate_limit(self, "comment"):
        self._err(429, "评论过于频繁，请稍后再试")
        return True
    hits = check_sensitive(c, content)
    if any(h["level"] == 0 for h in hits):
        self._err(400, "评论包含敏感词")
        return True
    cid = uuid.uuid4().hex
    c.execute(
        "INSERT INTO community_post_comments(id,post_id,user_id,content,images,sticker,created)"
        " VALUES(?,?,?,?,?,?,?)",
        (cid, pid, uid, content, json.dumps(images, ensure_ascii=False), sticker, time.time()))
    c.execute("UPDATE community_posts SET comment_count=comment_count+1 WHERE id=?", (pid,))
    record_behavior(c, uid, pid, "comment", 5.0, _behavior_meta(d))
    # 经验：评论者 +2；作者被评论 +2
    add_exp(c, uid, EXP_RULES["comment"])
    if d["user_id"] != uid:
        add_exp(c, d["user_id"], EXP_RULES["be_comment"])
        notify(c, d["user_id"], "community_comment", "收到新评论",
               "%s 评论了你的%s：%s" % (user_mini(c, uid)["name"] or "用户",
                                      "视频" if d["type"] == "video" else "帖子",
                                      content[:50]),
               from_uid=uid, from_name=user_mini(c, uid)["name"],
               extra={"postId": pid, "commentId": cid})
    task_progress(c, uid, "t_first_comment", 1)
    cmt_row = c.execute("SELECT * FROM community_post_comments WHERE id=?", (cid,)).fetchone()
    c.commit()
    self._ok({"comment": decorate_comment(c, cmt_row, uid)})
    return True


def _handle_comments_list(self, c, u, api, method):
    m = re.match(r"^/post/([\w\-]+)/comments$", api)
    if not m:
        return False
    pid = m.group(1)
    viewer = _uid(c, self)
    post_row = c.execute("SELECT * FROM community_posts WHERE id=? AND status=1", (pid,)).fetchone()
    if not post_row:
        self._err(404, "帖子不存在")
        return True
    post = row_dict(post_row)
    if not _interactive_ok(post) and post["user_id"] != viewer:
        self._err(404, "帖子不存在")
        return True
    query = urllib.parse.parse_qs(u.query)
    page = max(1, int((query.get("page") or ["1"])[0] or 1))
    size = min(50, max(1, int((query.get("size") or ["20"])[0] or 20)))
    rows = c.execute(
        "SELECT * FROM community_post_comments WHERE post_id=? AND status=1"
        " ORDER BY pinned DESC, created ASC LIMIT ? OFFSET ?",
        (pid, size, (page - 1) * size)).fetchall()
    c.commit()
    self._ok({"list": [decorate_comment(c, r, viewer) for r in rows],
              "page": page, "size": size, "hasMore": len(rows) == size})
    return True


def _handle_comment_like(self, c, u, api, method):
    m = re.match(r"^/comment/([\w\-]+)/like$", api)
    if not m:
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    cid = m.group(1)
    row = c.execute("SELECT * FROM community_post_comments WHERE id=? AND status=1", (cid,)).fetchone()
    if not row:
        self._err(404, "评论不存在")
        return True
    d = row_dict(row)
    parent = c.execute("SELECT * FROM community_posts WHERE id=? AND status=1",
                       (d.get("post_id"),)).fetchone()
    if not parent or not _interactive_ok(row_dict(parent)):
        self._err(404, "评论不存在")
        return True
    if method == "DELETE":
        exists = c.execute(
            "SELECT 1 FROM community_post_comment_likes WHERE user_id=? AND comment_id=?",
            (uid, cid)).fetchone()
        if not exists:
            c.commit()
            self._ok({"liked": False, "likeCount": d["like_count"]})
            return True
        c.execute("DELETE FROM community_post_comment_likes WHERE user_id=? AND comment_id=?",
                  (uid, cid))
        c.execute("UPDATE community_post_comments SET like_count="
                  "CASE WHEN like_count>0 THEN like_count-1 ELSE 0 END WHERE id=?", (cid,))
        c.commit()
        count = c.execute(
            "SELECT like_count FROM community_post_comments WHERE id=?", (cid,)).fetchone()[0]
        self._ok({"liked": False, "likeCount": count})
        return True
    if not rate_limit(self, "like"):
        self._err(429, "操作过于频繁")
        return True
    exists = c.execute("SELECT 1 FROM community_post_comment_likes WHERE user_id=? AND comment_id=?",
                       (uid, cid)).fetchone()
    if exists:
        c.commit()
        self._ok({"liked": True, "likeCount": d["like_count"]})
        return True
    c.execute("INSERT INTO community_post_comment_likes(user_id,comment_id,created) VALUES(?,?,?)",
              (uid, cid, time.time()))
    c.execute("UPDATE community_post_comments SET like_count=like_count+1 WHERE id=?", (cid,))
    if d["user_id"] != uid:
        add_exp(c, d["user_id"], EXP_RULES["be_liked_text"])
    c.commit()
    self._ok({"liked": True, "likeCount": d["like_count"] + 1})
    return True


def _handle_poll_vote(self, c, u, api, method):
    if api != "/poll/vote":
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    body = _parse_body(self)
    pid = (body.get("postId") or "").strip()
    try:
        option = int(body.get("option")) if body.get("option") is not None else -1
    except (TypeError, ValueError):
        option = -1
    row = c.execute("SELECT * FROM community_posts WHERE id=? AND status=1", (pid,)).fetchone()
    if not row:
        self._err(404, "帖子不存在")
        return True
    d = row_dict(row)
    if not _interactive_ok(d):
        self._err(404, "帖子不存在")
        return True
    if d.get("type") != "poll" or not d.get("poll"):
        self._err(400, "该内容不是投票帖")
        return True
    try:
        poll = json.loads(d["poll"])
    except Exception:
        self._err(500, "投票数据异常")
        return True
    if poll.get("endAt", 0) and poll["endAt"] <= time.time():
        self._err(403, "投票已结束")
        return True
    if option < 0 or option >= len(poll.get("options", [])):
        self._err(400, "选项无效")
        return True
    if not rate_limit(self, "poll"):
        self._err(429, "操作过于频繁")
        return True
    # 先取写锁，再重读 poll / 查重 / 写票 / 写回计数，避免并发丢票。
    try:
        c.execute("BEGIN IMMEDIATE")
    except sqlite3.OperationalError:
        self._err(503, "投票繁忙，请稍后再试")
        return True
    try:
        fresh = c.execute("SELECT poll FROM community_posts WHERE id=? AND status=1"
                          " AND audit_status=1 AND taken_down=0", (pid,)).fetchone()
        if not fresh:
            c.rollback()
            self._err(404, "帖子不存在")
            return True
        try:
            poll = json.loads(fresh[0])
        except Exception:
            c.rollback()
            self._err(500, "投票数据异常")
            return True
        if poll.get("endAt", 0) and poll["endAt"] <= time.time():
            c.rollback()
            self._err(403, "投票已结束")
            return True
        exists = c.execute("SELECT 1 FROM community_poll_votes WHERE user_id=? AND post_id=?",
                           (uid, pid)).fetchone()
        if exists:
            c.commit()
            self._err(400, "已投过票")
            return True
        c.execute("INSERT INTO community_poll_votes(user_id,post_id,option,created) VALUES(?,?,?,?)",
                  (uid, pid, option, time.time()))
        record_behavior(c, uid, pid, "vote", 2.0, _behavior_meta(d))
        votes = poll.get("votes") or [0] * len(poll["options"])
        if len(votes) < len(poll["options"]):
            votes = votes + [0] * (len(poll["options"]) - len(votes))
        votes[option] += 1
        poll["votes"] = votes
        c.execute("UPDATE community_posts SET poll=? WHERE id=?",
                  (json.dumps(poll, ensure_ascii=False), pid))
        add_exp(c, uid, EXP_RULES["vote"])
        c.commit()
    except Exception:
        c.rollback()
        raise
    self._ok({"voted": True, "option": option, "poll": poll})
    return True


# ---------------- 编辑 / 删除 / 草稿 / 收藏 ----------------
def _handle_edit(self, c, u, api, method):
    m = re.match(r"^/post/([\w\-]+)/edit$", api)
    if not m:
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    pid = m.group(1)
    row = c.execute("SELECT * FROM community_posts WHERE id=? AND status=1", (pid,)).fetchone()
    if not row:
        self._err(404, "帖子不存在")
        return True
    d = row_dict(row)
    if d["user_id"] != uid:
        self._err(403, "只能编辑自己的内容")
        return True
    if d.get("taken_down"):
        self._err(403, "已下架内容不可编辑")
        return True
    body = _parse_body(self)
    content = (body.get("content") or "").strip()
    if len(content) > MAX_CONTENT:
        self._err(400, "内容过长")
        return True
    images = body.get("images") or []
    if not isinstance(images, list):
        images = []
    images = [x for x in images if isinstance(x, str)][:MAX_IMAGES]
    topic_names = body.get("topic") or parse_topics(content)
    mention_list = body.get("mentions") or parse_mentions(c, content)
    if not isinstance(topic_names, list):
        topic_names = parse_topics(content)
    if not isinstance(mention_list, list):
        mention_list = parse_mentions(c, content)
    mention_list = [{"id": m["id"], "name": m.get("name", "")} for m in mention_list
                    if isinstance(m, dict) and m.get("id")]
    board_id = (body.get("boardId") or "").strip()
    attachments = None
    if "attachments" in body:
        attachments, attach_err = normalize_attachments(uid, body.get("attachments"))
        if attach_err:
            self._err(400, attach_err)
            return True
    hits = check_sensitive(c, content)
    if any(h["level"] == 0 for h in hits):
        self._err(400, "内容包含敏感词")
        return True
    ensure_topics(c, topic_names)

    old_images = json.loads(d.get("images") or "[]")
    old_attachments = json.loads(d.get("attachments") or "[]")
    media_changed = images != old_images
    if attachments is not None:
        media_changed = media_changed or attachments != old_attachments
    needs_reaudit = media_changed or any(h["level"] == 1 for h in hits)
    old_status = d.get("audit_status", 0)
    audit_status = 1 if old_status == 1 and not needs_reaudit else 0
    audit_reason = d.get("audit_reason", "") if audit_status == 1 else ""
    audited_at = d.get("audited_at", 0) if audit_status == 1 else 0
    edited_at = time.time()

    # 编辑不重置 created：只写 edited_at，避免旧帖被顶到信息流最前。
    if attachments is None:
        c.execute(
            "UPDATE community_posts SET content=?, images=?, board_id=?, tag='',"
            " topic=?, mentions=?, audit_status=?, audit_reason=?, audited_at=?,"
            " edited_at=? WHERE id=?",
            (content, json.dumps(images, ensure_ascii=False), board_id,
             json.dumps(topic_names, ensure_ascii=False),
             json.dumps(mention_list, ensure_ascii=False), audit_status,
             audit_reason, audited_at, edited_at, pid))
    else:
        c.execute(
            "UPDATE community_posts SET content=?, images=?, board_id=?, tag='',"
            " topic=?, mentions=?, attachments=?, audit_status=?, audit_reason=?,"
            " audited_at=?, edited_at=? WHERE id=?",
            (content, json.dumps(images, ensure_ascii=False), board_id,
             json.dumps(topic_names, ensure_ascii=False),
             json.dumps(mention_list, ensure_ascii=False),
             json.dumps(attachments, ensure_ascii=False), audit_status,
             audit_reason, audited_at, edited_at, pid))
    if board_id != d.get("board_id", ""):
        if d.get("board_id"):
            bump_board_count(c, d["board_id"], -1)
        if board_id:
            bump_board_count(c, board_id, 1)
    for m in mention_list:
        if m["id"] != uid:
            notify(c, m["id"], "community_mention", "有人 @ 了你",
                   "%s 在编辑后的帖子中提到了你" % (user_mini(c, uid)["name"] or "用户"),
                   from_uid=uid, from_name=user_mini(c, uid)["name"],
                   extra={"postId": pid})
    new_row = c.execute("SELECT * FROM community_posts WHERE id=?", (pid,)).fetchone()
    c.commit()
    msg = "已更新"
    if audit_status != 1:
        msg = "已更新，仍在审核中" if old_status == 0 else "已更新，已重新提交审核"
    self._ok({"post": decorate_post(c, new_row, uid), "msg": msg})
    return True


def _handle_delete(self, c, u, api, method):
    if method != "DELETE":
        return False
    m = re.match(r"^/post/([\w\-]+)$", api)
    if not m:
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    pid = m.group(1)
    row = c.execute("SELECT * FROM community_posts WHERE id=?", (pid,)).fetchone()
    if not row:
        self._err(404, "帖子不存在")
        return True
    d = row_dict(row)
    is_admin = bool(c.execute("SELECT 1 FROM community_admins WHERE user_id=?", (uid,)).fetchone())
    if d["user_id"] != uid and not is_admin:
        self._err(403, "无权删除")
        return True
    if d.get("status") == 1 and d.get("board_id"):
        bump_board_count(c, d["board_id"], -1)
    c.execute("UPDATE community_posts SET status=0 WHERE id=?", (pid,))
    c.commit()
    self._ok({"deleted": True})
    return True


def _handle_fav_later(self, c, u, api, method):
    """/post/{id}/fav | /post/{id}/later（POST 添加 / DELETE 取消）"""
    m = re.match(r"^/post/([\w\-]+)/(fav|later)$", api)
    if not m:
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    pid, kind = m.group(1), m.group(2)
    row = c.execute("SELECT * FROM community_posts WHERE id=? AND status=1", (pid,)).fetchone()
    if not row:
        self._err(404, "帖子不存在")
        return True
    d = row_dict(row)
    if not _interactive_ok(d):
        self._err(404, "帖子不存在")
        return True
    if method == "DELETE":
        exists = c.execute(
            "SELECT 1 FROM community_favorites WHERE user_id=? AND post_id=? AND kind=?",
            (uid, pid, kind)).fetchone()
        if not exists:
            c.commit()
            self._ok({kind: False})
            return True
        c.execute("DELETE FROM community_favorites WHERE user_id=? AND post_id=? AND kind=?",
                  (uid, pid, kind))
        record_behavior(c, uid, pid, "unfav" if kind == "fav" else "unlater", -3.0)
        c.commit()
        self._ok({kind: False})
        return True
    if not rate_limit(self, "fav"):
        self._err(429, "操作过于频繁")
        return True
    exists = c.execute(
        "SELECT 1 FROM community_favorites WHERE user_id=? AND post_id=? AND kind=?",
        (uid, pid, kind)).fetchone()
    if exists:
        c.commit()
        self._ok({kind: True})
        return True
    c.execute("INSERT OR IGNORE INTO community_favorites(user_id,post_id,kind,created) VALUES(?,?,?,?)",
              (uid, pid, kind, time.time()))
    record_behavior(c, uid, pid, "fav" if kind == "fav" else "later",
                    5.0 if kind == "fav" else 2.0, _behavior_meta(d))
    c.commit()
    self._ok({kind: True})
    return True


def _handle_favorites(self, c, u, api, method):
    if api != "/favorites":
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    query = urllib.parse.parse_qs(u.query)
    kind = (query.get("kind") or ["fav"])[0]
    if kind not in ("fav", "later"):
        kind = "fav"
    page = max(1, int((query.get("page") or ["1"])[0] or 1))
    size = min(50, max(1, int((query.get("size") or ["20"])[0] or 20)))
    rows = c.execute(
        "SELECT p.* FROM community_posts p JOIN community_favorites f ON p.id=f.post_id"
        " WHERE f.user_id=? AND f.kind=? AND p.status=1"
        " AND p.audit_status=1 AND p.taken_down=0"
        " ORDER BY f.created DESC LIMIT ? OFFSET ?",
        (uid, kind, size, (page - 1) * size)).fetchall()
    c.commit()
    self._ok({"list": [decorate_post(c, r, uid) for r in rows],
              "page": page, "size": size, "hasMore": len(rows) == size})
    return True


def _handle_drafts(self, c, u, api, method):
    """POST /draft 保存；GET /drafts 列表；DELETE /draft/{id}"""
    if not (api == "/draft" or api == "/drafts" or re.match(r"^/draft/[\w\-]+$", api)):
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    if api == "/draft" and method == "POST":
        if not rate_limit(self, "post"):
            self._err(429, "操作过于频繁")
            return True
        body = _parse_body(self)
        did = (body.get("id") or "").strip()
        content = (body.get("content") or "").strip()[:MAX_CONTENT]
        images = body.get("images") or []
        if not isinstance(images, list):
            images = []
        images = [x for x in images if isinstance(x, str)][:MAX_IMAGES]
        board_id = (body.get("boardId") or "").strip()
        topic_names = body.get("topic") or []
        mention_list = body.get("mentions") or []
        poll = body.get("poll")
        now = time.time()
        if did:
            c.execute(
                "UPDATE community_drafts SET type=?,content=?,images=?,board_id=?,topic=?,mentions=?,poll=?,updated=?"
                " WHERE id=? AND user_id=?",
                (body.get("type") or "text", content, json.dumps(images, ensure_ascii=False),
                 board_id, json.dumps(topic_names, ensure_ascii=False),
                 json.dumps(mention_list, ensure_ascii=False),
                 json.dumps(poll, ensure_ascii=False) if poll else "", now, did, uid))
        else:
            did = uuid.uuid4().hex
            c.execute(
                "INSERT INTO community_drafts(id,user_id,type,content,images,board_id,topic,mentions,poll,created,updated)"
                " VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                (did, uid, body.get("type") or "text", content,
                 json.dumps(images, ensure_ascii=False), board_id,
                 json.dumps(topic_names, ensure_ascii=False),
                 json.dumps(mention_list, ensure_ascii=False),
                 json.dumps(poll, ensure_ascii=False) if poll else "", now, now))
        c.commit()
        self._ok({"id": did})
        return True
    if api == "/drafts":
        rows = c.execute("SELECT * FROM community_drafts WHERE user_id=? ORDER BY updated DESC",
                         (uid,)).fetchall()
        out = []
        for r in rows:
            d = row_dict(r)
            out.append({"id": d["id"], "type": d["type"], "content": d["content"],
                        "images": json.loads(d.get("images") or "[]"),
                        "video": d.get("video", ""), "boardId": d.get("board_id", ""),
                        "topic": json.loads(d.get("topic") or "[]"),
                        "mentions": json.loads(d.get("mentions") or "[]"),
                        "updated": d.get("updated", 0)})
        c.commit()
        self._ok({"list": out})
        return True
    m = re.match(r"^/draft/([\w\-]+)$", api)
    if m and method == "DELETE":
        c.execute("DELETE FROM community_drafts WHERE id=? AND user_id=?", (m.group(1), uid))
        c.commit()
        self._ok({"deleted": True})
        return True
    return False


# ---------------- 配乐：社区专用只读代理 ----------------
def _fmt_dur(d):
    if not d or d <= 0:
        return "--:--"
    return "%d:%02d" % (int(d) // 60, int(d) % 60)


def _music_tracks_from_db(c, params):
    """音乐进程不可用时的本地兜底：直接读共享 tracks 表。

    只负责“列表仍可打开”，不生成播放签名；封面仍指向音乐静态接口，
    音乐进程恢复后自动回到代理路径。
    """
    offset = max(0, int(params.get("offset") or 0))
    limit = max(1, min(int(params.get("limit") or 20), 50))
    q = (params.get("q") or "").strip()[:80]
    where = "t.offline=0 AND t.fname!=''"
    args = []
    if q:
        like = "%" + q + "%"
        where += (" AND (t.title LIKE ? OR t.artist LIKE ? OR t.album LIKE ?"
                  " OR COALESCE(u.name,'') LIKE ?)")
        args = [like, like, like, like]
    total = c.execute(
        "SELECT COUNT(*) FROM tracks t LEFT JOIN users u ON u.id=t.user_id WHERE " + where,
        args).fetchone()[0]
    rows = c.execute(
        """SELECT t.id,t.title,t.artist,t.album,t.cover,t.fname,t.size,t.dur,t.created,
                  t.play_count,t.like_count,t.share_count,t.user_id,t.lrc,
                  COALESCE(u.name,''),
                  (SELECT COUNT(*) FROM comments cm WHERE cm.track_id=t.id)
           FROM tracks t LEFT JOIN users u ON u.id=t.user_id
           WHERE """ + where + """
           ORDER BY t.created DESC, t.id DESC LIMIT ? OFFSET ?""",
        args + [limit, offset]).fetchall()
    out = []
    for r in rows:
        cover = r[4] or ""
        out.append({
            "id": r[0], "key": "t:" + str(r[0]),
            "title": r[1] or "", "artist": r[2] or "", "album": r[3] or "",
            "cover": (settings.public_base + "/music/cover/" +
                      urllib.parse.quote(str(r[0]))) if cover else "",
            "fname": r[5] or "", "size": r[6] or 0, "dur": r[7] or 0,
            "durText": _fmt_dur(r[7]), "created": r[8] or 0,
            "playCount": r[9] or 0, "likeCount": r[10] or 0,
            "shareCount": r[11] or 0, "userId": r[12] or "",
            "userName": r[14] or "", "hasLyric": bool(r[13]),
            "commentCount": r[15] or 0, "isLiked": False,
        })
    return {"list": out, "total": int(total), "offset": offset,
            "limit": limit, "hasMore": offset + len(out) < int(total)}


def _handle_music_tracks(self, c, u, api, method):
    """社区发布页配乐曲库：转发到音乐项目的社区专用接口。

    音乐项目 /api/community/tracks 负责 tracks 表的稳定分页、搜索和可播
    封面/文件名；这里只做同机 localhost 转发，已安装的社区客户端无需改包。
    """
    if api != "/music/tracks" or method != "GET":
        return False
    qs = urllib.parse.parse_qs(u.query)
    params = {
        "offset": (qs.get("offset", ["0"])[0] or "0").strip(),
        "limit": (qs.get("limit", ["20"])[0] or "20").strip(),
    }
    q = (qs.get("q", [""])[0] or "").strip()
    if q:
        params["q"] = q
    url = settings.music_api_base + "/api/community/tracks?" + urllib.parse.urlencode(params)
    try:
        # 把真实客户端 IP 传给音乐服务，避免所有社区请求在音乐侧共用
        # 127.0.0.1 限流桶（否则并发用户会一起被 429）。
        real_ip = (client_ip(self) or "").replace("\r", "").replace("\n", "")[:64]
        headers = {"Accept": "application/json"}
        if real_ip:
            headers["X-Real-IP"] = real_ip
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=8) as r:
            data = json.loads(r.read().decode("utf-8"))
        if not isinstance(data, dict):
            self._err(502, "配乐服务返回格式异常")
        else:
            # 封面统一改走社区代理，音乐进程停掉后封面也能加载。
            prefix = settings.music_public_base.rstrip("/") + "/api/cover/"
            for item in (data.get("list") or []):
                cover = item.get("cover") if isinstance(item, dict) else None
                if isinstance(cover, str) and cover.startswith(prefix):
                    item["cover"] = settings.public_base + "/music/cover/" + cover[len(prefix):]
            self._ok(data)
    except Exception:
        # 音乐进程停掉时，/music/tracks 不能跟着 502；直接读共享 tracks 表，
        # 保证发布页曲库、搜索和分页仍可用。
        try:
            self._ok(_music_tracks_from_db(c, params))
        except Exception:
            self._err(502, "配乐服务暂时不可用")
    return True


# ---------------- 汇总路由 ----------------
def dispatch(self, c, u, api, method):
    handlers = [
        _handle_music_tracks,
        _handle_post, _handle_video_post, _handle_post_detail, _handle_user_posts,
        _handle_like, _handle_share, _handle_comment, _handle_comments_list,
        _handle_comment_like, _handle_poll_vote, _handle_edit, _handle_delete,
        _handle_fav_later, _handle_favorites, _handle_drafts,
    ]
    for h in handlers:
        if h(self, c, u, api, method):
            return True
    return False
