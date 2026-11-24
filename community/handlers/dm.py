
# -*- coding: utf-8 -*-
"""流萤社区 · 私信 IM（1对1，仅互相关注可发）

表：
- community_dm_messages  : 消息明细（本轮新建）
- community_conversations: 会话聚合（预留表，user_a/user_b 为字典序小前大后）

API：
- GET  /dm/conversations            会话列表（含对方资料/最后消息/未读）
- GET  /dm/messages?peer=&before=   聊天记录（created 降序取，升序返回）
- POST /dm/send {peer, content}     发送（互关校验 + WS 实时推送）
- POST /dm/read {peer}              标记该会话全部已读
- GET  /dm/unread                   私信总未读

WS 下行：{"kind":"dm","dm":{convId,from:{id,name,avatar},content,created},"unread":N}
"""
import time
import urllib.parse
import uuid

from common import resolve_token, row_dict, user_mini

MAX_DM_LEN = 2000
_PAGE_SIZE = 30


def _uid(c, handler):
    return resolve_token(c, handler.headers.get("Authorization", ""))


def _body(h):
    return h._json_body() or {}


def _conv_id(a, b):
    a, b = str(a), str(b)
    return ("%s_%s" % (min(a, b), max(a, b)))


def _peer_of(conv_row, uid):
    return conv_row["user_b"] if str(conv_row["user_a"]) == str(uid) else conv_row["user_a"]


def _mutual_follow(c, a, b):
    if a == b:
        return False
    if not c.execute("SELECT 1 FROM follows WHERE follower_id=? AND following_id=?",
                     (a, b)).fetchone():
        return False
    return bool(c.execute("SELECT 1 FROM follows WHERE follower_id=? AND following_id=?",
                          (b, a)).fetchone())


def _unread_total(c, uid):
    return c.execute(
        "SELECT COUNT(*) FROM community_dm_messages WHERE receiver_id=? AND is_read=0",
        (uid,)).fetchone()[0]


def dispatch(self, c, u, api, method):
    if not api.startswith("/dm"):
        return False
    uid = _uid(c, self)
    # ---------------- 互关好友（分享选人） ----------------
    if api == "/dm/friends" and method == "GET":
        if not uid:
            self._err(401, "未登录")
            return True
        q = urllib.parse.parse_qs(u.query)
        kw = (q.get("q") or [""])[0].strip()
        limit = min(100, max(1, int((q.get("limit") or ["60"])[0] or 60)))
        like = "%" + kw + "%"
        rows = c.execute(
            "SELECT u.id FROM users u"
            " WHERE u.id IN (SELECT following_id FROM follows WHERE follower_id=?)"
            " AND u.id IN (SELECT follower_id FROM follows WHERE following_id=?)"
            " AND (?='' OR u.name LIKE ?)"
            " ORDER BY u.name LIMIT ?",
            (uid, uid, kw, like, limit)).fetchall()
        out = []
        for r in rows:
            info = user_mini(c, r[0], uid)
            pub = c.execute("SELECT title FROM users WHERE id=?", (r[0],)).fetchone()
            info["title"] = (pub[0] if pub else "") or ""
            info["following"] = True
            out.append(info)
        c.commit()
        self._ok({"list": out})
        return True

    # ---------------- 会话列表 ----------------
    if api == "/dm/conversations" and method == "GET":
        if not uid:
            self._err(401, "未登录")
            return True
        q = urllib.parse.parse_qs(u.query)
        page = max(1, int((q.get("page") or ["1"])[0] or 1))
        size = min(50, max(1, int((q.get("size") or ["20"])[0] or 20)))
        rows = c.execute(
            "SELECT * FROM community_conversations WHERE user_a=? OR user_b=?"
            " ORDER BY last_time DESC LIMIT ? OFFSET ?",
            (uid, uid, size, (page - 1) * size)).fetchall()
        out = []
        for r in rows:
            d = row_dict(r)
            pid = _peer_of(d, uid)
            pinfo = c.execute("SELECT id,name,avatar,title,verified,verified_label"
                              " FROM users WHERE id=?", (pid,)).fetchone()
            frame_row = c.execute(
                "SELECT frame_id FROM community_user_frames WHERE user_id=?",
                (pid,)).fetchone()
            label = (pinfo[5] if pinfo else "") or ""
            unread = d["unread_a"] if str(d["user_a"]) == str(uid) else d["unread_b"]
            out.append({
                "id": d["id"],
                "peer": {
                    "id": pid,
                    "name": (pinfo[1] if pinfo else "") or "",
                    "avatar": (pinfo[2] if pinfo else "") or "",
                    "title": (pinfo[3] if pinfo else "") or "",
                    "verified": (pinfo[4] if pinfo else "") or "",
                    "verifiedLabel": label,
                    "isAi": label.strip().upper() == "AI",
                    "frameId": (frame_row[0] if frame_row else "") or "",
                },
                "lastMsg": d["last_msg"] or "",
                "lastType": d["last_type"] or "text",
                "lastTime": d["last_time"] or 0,
                "unread": unread or 0,
            })
        c.commit()
        self._ok({"list": out, "hasMore": len(rows) == size})
        return True

    # ---------------- 聊天记录 ----------------
    if api == "/dm/messages" and method == "GET":
        if not uid:
            self._err(401, "未登录")
            return True
        q = urllib.parse.parse_qs(u.query)
        peer = (q.get("peer") or [""])[0].strip()
        if not peer:
            self._err(400, "缺少 peer")
            return True
        before = float((q.get("before") or ["0"])[0] or 0)
        limit = min(50, max(1, int((q.get("limit") or ["30"])[0] or 30)))
        conv = _conv_id(uid, peer)
        rows = c.execute(
            "SELECT * FROM community_dm_messages WHERE conv_id=? AND created<?"
            " ORDER BY created DESC LIMIT ?",
            (conv, before if before > 0 else time.time() + 1, limit)).fetchall()
        msgs = [{
            "id": d["id"], "senderId": d["sender_id"], "content": d["content"],
            "msgType": d["msg_type"] or "text", "created": d["created"],
            "isRead": d["is_read"],
        } for d in (row_dict(r) for r in rows)]
        msgs.reverse()  # 升序返回（最早在上）
        c.commit()
        self._ok({"list": msgs, "peer": peer})
        return True

    # ---------------- 发送 ----------------
    if api == "/dm/send" and method == "POST":
        if not uid:
            self._err(401, "未登录")
            return True
        body = _body(self)
        peer = (body.get("peer") or "").strip()
        content = (body.get("content") or "").strip()
        mtype = (body.get("type") or "text").strip()
        if mtype not in ("text", "image", "video", "location", "card"):
            mtype = "text"
        if not peer:
            self._err(400, "缺少 peer")
            return True
        if not content:
            self._err(400, "消息不能为空")
            return True
        if len(content) > MAX_DM_LEN:
            self._err(400, "消息过长（上限 2000 字）")
            return True
        if not _mutual_follow(c, uid, peer):
            self._err(403, "仅互相关注的用户可以私信")
            return True
        mid = uuid.uuid4().hex
        created = time.time()
        conv = _conv_id(uid, peer)
        a, b = str(uid), str(peer)
        ua, ub = (a, b) if a <= b else (b, a)
        c.execute(
            "INSERT INTO community_dm_messages(id,conv_id,sender_id,receiver_id,content,created,is_read,msg_type)"
            " VALUES(?,?,?,?,?,?,0,?)", (mid, conv, uid, peer, content, created, mtype))
        # 会话 upsert：自己的 unread 不变，对方 unread +1
        preview = {"image": "[图片]", "video": "[视频]",
                   "location": "[位置]", "card": "[名片]"}.get(mtype, content)
        if str(uid) == ua:
            c.execute(
                "INSERT INTO community_conversations(id,user_a,user_b,last_msg,last_type,last_time,unread_a,unread_b,created)"
                " VALUES(?,?,?,?,?,?,0,1,?)"
                " ON CONFLICT(id) DO UPDATE SET last_msg=excluded.last_msg,"
                " last_type=excluded.last_type, last_time=excluded.last_time,"
                " unread_b=unread_b+1",
                (conv, ua, ub, preview, mtype, created, created))
        else:
            c.execute(
                "INSERT INTO community_conversations(id,user_a,user_b,last_msg,last_type,last_time,unread_a,unread_b,created)"
                " VALUES(?,?,?,?,?,?,1,0,?)"
                " ON CONFLICT(id) DO UPDATE SET last_msg=excluded.last_msg,"
                " last_type=excluded.last_type, last_time=excluded.last_time,"
                " unread_a=unread_a+1",
                (conv, ua, ub, preview, mtype, created, created))
        c.commit()
        # WS 实时推送接收方（带消息 id / 会话摘要 / 会话未读，列表可本地增量更新）
        try:
            from handlers import ws as H_WS
            unread = _unread_total(c, peer)
            conv_unread = c.execute(
                "SELECT COUNT(*) FROM community_dm_messages"
                " WHERE conv_id=? AND receiver_id=? AND is_read=0",
                (conv, peer)).fetchone()[0]
            pinfo = c.execute("SELECT id,name,avatar FROM users WHERE id=?", (uid,)).fetchone()
            H_WS.ws_push(peer, {
                "kind": "dm",
                "dm": {
                    "id": mid, "convId": conv,
                    "from": {"id": uid,
                             "name": (pinfo[1] if pinfo else "") or "",
                             "avatar": (pinfo[2] if pinfo else "") or ""},
                    "content": content, "msgType": mtype, "created": created,
                    "preview": preview, "convUnread": conv_unread,
                },
                "unread": unread,
            })
        except Exception:
            pass
        self._ok({"id": mid, "created": created})
        return True

    # ---------------- 标记已读 ----------------
    if api == "/dm/read" and method == "POST":
        if not uid:
            self._err(401, "未登录")
            return True
        body = _body(self)
        peer = (body.get("peer") or "").strip()
        if not peer:
            self._err(400, "缺少 peer")
            return True
        conv = _conv_id(uid, peer)
        c.execute("UPDATE community_dm_messages SET is_read=1"
                  " WHERE conv_id=? AND receiver_id=? AND is_read=0", (conv, uid))
        # 清零会话侧 unread
        a, b = str(uid), str(peer)
        ua, ub = (a, b) if a <= b else (b, a)
        if str(uid) == ua:
            c.execute("UPDATE community_conversations SET unread_a=0 WHERE id=?", (conv,))
        else:
            c.execute("UPDATE community_conversations SET unread_b=0 WHERE id=?", (conv,))
        c.commit()
        # 已读回执：推送给发送方（peer），让聊天页己方气泡实时变「已读」
        try:
            from handlers import ws as H_WS
            H_WS.ws_push(peer, {
                "kind": "dm_read",
                "convId": conv,
                "peer": uid,
                "readAt": time.time(),
            })
        except Exception:
            pass
        self._ok({"read": True})
        return True

    # ---------------- 全部会话已读 ----------------
    if api == "/dm/read-all" and method == "POST":
        if not uid:
            self._err(401, "未登录")
            return True
        # 必须消费客户端 body：否则 HTTP/1.1 keep-alive 会把 "{}" 留到下一个请求，
        # 下一个 GET 会被解析成 "{}GET" 并返回 501。
        _body(self)
        targets = []
        rows = c.execute(
            "SELECT * FROM community_conversations WHERE user_a=? OR user_b=?",
            (uid, uid)).fetchall()
        for r in rows:
            d = row_dict(r)
            unread = d["unread_a"] if str(d["user_a"]) == str(uid) else d["unread_b"]
            if (unread or 0) > 0:
                targets.append((d["id"], _peer_of(d, uid)))
        c.execute("UPDATE community_dm_messages SET is_read=1"
                  " WHERE receiver_id=? AND is_read=0", (uid,))
        c.execute(
            "UPDATE community_conversations SET"
            " unread_a=CASE WHEN user_a=? THEN 0 ELSE unread_a END,"
            " unread_b=CASE WHEN user_b=? THEN 0 ELSE unread_b END"
            " WHERE user_a=? OR user_b=?",
            (uid, uid, uid, uid))
        c.commit()
        try:
            from handlers import ws as H_WS
            for conv, peer in targets:
                H_WS.ws_push(peer, {
                    "kind": "dm_read",
                    "convId": conv,
                    "peer": uid,
                    "readAt": time.time(),
                })
        except Exception:
            pass
        self._ok({"read": True, "count": len(targets)})
        return True

    # ---------------- 总未读 ----------------
    if api == "/dm/unread" and method == "GET":
        if not uid:
            self._ok({"unread": 0})
            return True
        n = _unread_total(c, uid)
        c.commit()
        self._ok({"unread": n})
        return True
    return False
