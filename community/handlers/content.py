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
import urllib.parse

from common import (db, rate_limit, resolve_token, public_user, user_mini,
                    decorate_post, decorate_comment, notify, official_msg,
                    add_exp, EXP_RULES, parse_mentions, parse_topics,
                    ensure_topics, check_sensitive, task_progress,
                    is_blocked, blocked_by, row_dict)

MAX_CONTENT = 2000
MAX_IMAGES = 3
MAX_TOPIC = 10


def _uid(c, handler):
    return resolve_token(c, handler.headers.get("Authorization", ""))


def _parse_body(h):
    """尝试 JSON；失败尝试 multipart。返回 dict。"""
    body = h._json_body()
    if body is None:
        body = {}
    return body


def _post_created(c, uid, ptype, content, images, video, cover, duration,
                 board_id, topic_names, mention_list, poll=None):
    """公共创建逻辑：落库 + 话题 + @ 通知 + 敏感词拦截/转审 + 经验 + 任务。"""
    now = time.time()
    pid = uuid.uuid4().hex
    # 敏感词：level=0 拦截；level=1 标记待审（默认已是待审 0，无差别）
    hits = check_sensitive(c, content)
    block_hits = [h["word"] for h in hits if h["level"] == 0]
    if block_hits:
        return None, "内容包含敏感词：" + "、".join(block_hits[:5])
    # 话题入库
    ensure_topics(c, topic_names)
    c.execute(
        """INSERT INTO community_posts(id,user_id,type,content,images,video,cover,duration,
           board_id,tag,topic,mentions,poll,created,audit_status)
           VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (pid, uid, ptype, content, json.dumps(images, ensure_ascii=False),
         video, cover, duration, board_id, "", json.dumps(topic_names, ensure_ascii=False),
         json.dumps(mention_list, ensure_ascii=False),
         json.dumps(poll, ensure_ascii=False) if poll else "", now, 0))
    # 版块计数
    if board_id:
        c.execute("UPDATE community_boards SET post_count=post_count+1 WHERE id=?", (board_id,))
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
                   from_uid=uid, from_name=user_mini(c, uid)["name"])
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
    pid, err = _post_created(c, uid, "poll" if poll else "text", content, images,
                             "", "", 0, board_id, topic_names, mention_list, poll)
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
    pid, err = _post_created(c, uid, "video", content, [], video, cover, duration,
                             board_id, topic_names, mention_list, None)
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
    viewer = _uid(c, self)
    # 隐私：主页仅关注可见
    prefs = c.execute("SELECT profile_visible FROM community_user_prefs WHERE user_id=?",
                      (target,)).fetchone()
    if prefs and prefs[0] == 1 and viewer != target:
        if not (viewer and c.execute("SELECT 1 FROM follows WHERE follower_id=? AND following_id=?",
                                     (viewer, target)).fetchone()):
            self._err(403, "该用户主页仅关注者可见")
            return True
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
    args += [size, (page - 1) * size]
    rows = c.execute(sql, args).fetchall()
    c.commit()
    self._ok({"list": [decorate_post(c, r, viewer) for r in rows],
              "page": page, "size": size, "hasMore": len(rows) == size})
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
    if method == "DELETE":
        c.execute("DELETE FROM community_post_likes WHERE user_id=? AND post_id=?", (uid, pid))
        c.execute("UPDATE community_posts SET like_count=MAX(0,like_count-1) WHERE id=?", (pid,))
        c.commit()
        self._ok({"liked": False, "likeCount": d["like_count"] - 1})
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
    # 经验：作者被赞（视频 3 / 其他 2）；点赞者 +1（日上限由调用侧控制）
    author = d["user_id"]
    if author != uid:
        gain = EXP_RULES["be_liked_video"] if d["type"] == "video" else EXP_RULES["be_liked_text"]
        add_exp(c, author, gain)
        notify(c, author, "community_like", "收到新点赞",
               "%s 赞了你的%s" % (user_mini(c, uid)["name"] or "用户",
                                 "视频" if d["type"] == "video" else "帖子"),
               from_uid=uid, from_name=user_mini(c, uid)["name"])
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
    # 经验：评论者 +2；作者被评论 +2
    add_exp(c, uid, EXP_RULES["comment"])
    if d["user_id"] != uid:
        add_exp(c, d["user_id"], EXP_RULES["be_comment"])
        notify(c, d["user_id"], "community_comment", "收到新评论",
               "%s 评论了你的%s：%s" % (user_mini(c, uid)["name"] or "用户",
                                      "视频" if d["type"] == "video" else "帖子",
                                      content[:50]),
               from_uid=uid, from_name=user_mini(c, uid)["name"])
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
    if method == "DELETE":
        c.execute("DELETE FROM community_post_comment_likes WHERE user_id=? AND comment_id=?", (uid, cid))
        c.execute("UPDATE community_post_comments SET like_count=MAX(0,like_count-1) WHERE id=?", (cid,))
        c.commit()
        self._ok({"liked": False, "likeCount": d["like_count"] - 1})
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
    option = int(body.get("option") or -1)
    row = c.execute("SELECT * FROM community_posts WHERE id=? AND status=1", (pid,)).fetchone()
    if not row:
        self._err(404, "帖子不存在")
        return True
    d = row_dict(row)
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
    exists = c.execute("SELECT 1 FROM community_poll_votes WHERE user_id=? AND post_id=?",
                       (uid, pid)).fetchone()
    if exists:
        self._err(400, "已投过票")
        return True
    c.execute("INSERT INTO community_poll_votes(user_id,post_id,option,created) VALUES(?,?,?,?)",
              (uid, pid, option, time.time()))
    votes = poll.get("votes") or [0] * len(poll["options"])
    if len(votes) < len(poll["options"]):
        votes = votes + [0] * (len(poll["options"]) - len(votes))
    votes[option] += 1
    poll["votes"] = votes
    c.execute("UPDATE community_posts SET poll=? WHERE id=?", (json.dumps(poll, ensure_ascii=False), pid))
    add_exp(c, uid, EXP_RULES["vote"])
    c.commit()
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
    hits = check_sensitive(c, content)
    if any(h["level"] == 0 for h in hits):
        self._err(400, "内容包含敏感词")
        return True
    ensure_topics(c, topic_names)
    # 编辑后回待审（重新审核）
    c.execute(
        "UPDATE community_posts SET content=?, images=?, board_id=?, tag='',"
        " topic=?, mentions=?, audit_status=0, audit_reason='', edited_at=?, created=? WHERE id=?",
        (content, json.dumps(images, ensure_ascii=False), board_id,
         json.dumps(topic_names, ensure_ascii=False),
         json.dumps(mention_list, ensure_ascii=False), time.time(), time.time(), pid))
    for m in mention_list:
        if m["id"] != uid:
            notify(c, m["id"], "community_mention", "有人 @ 了你",
                   "%s 在编辑后的帖子中提到了你" % (user_mini(c, uid)["name"] or "用户"),
                   from_uid=uid, from_name=user_mini(c, uid)["name"])
    new_row = c.execute("SELECT * FROM community_posts WHERE id=?", (pid,)).fetchone()
    c.commit()
    self._ok({"post": decorate_post(c, new_row, uid), "msg": "已重新提交审核"})
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
    row = c.execute("SELECT 1 FROM community_posts WHERE id=? AND status=1", (pid,)).fetchone()
    if not row:
        self._err(404, "帖子不存在")
        return True
    if method == "DELETE":
        c.execute("DELETE FROM community_favorites WHERE user_id=? AND post_id=? AND kind=?",
                  (uid, pid, kind))
        c.commit()
        self._ok({kind: False})
        return True
    if not rate_limit(self, "fav"):
        self._err(429, "操作过于频繁")
        return True
    c.execute("INSERT OR IGNORE INTO community_favorites(user_id,post_id,kind,created) VALUES(?,?,?,?)",
              (uid, pid, kind, time.time()))
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


# ---------------- 汇总路由 ----------------
def dispatch(self, c, u, api, method):
    handlers = [
        _handle_post, _handle_video_post, _handle_post_detail, _handle_user_posts,
        _handle_like, _handle_share, _handle_comment, _handle_comments_list,
        _handle_comment_like, _handle_poll_vote, _handle_edit, _handle_delete,
        _handle_fav_later, _handle_favorites, _handle_drafts,
    ]
    for h in handlers:
        if h(self, c, u, api, method):
            return True
    return False
