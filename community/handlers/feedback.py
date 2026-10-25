# -*- coding: utf-8 -*-
"""流萤社区 · 意见反馈。

POST /feedback        提交反馈（登录；type=bug|suggestion|other）
GET  /feedback/mine   我的反馈列表（按时间倒序）
管理端：/admin/feedback（列表 + 状态/回复处理）见 admin_api.py
"""
import re
import json
import time
import uuid
import urllib.parse

from common import db, resolve_token, rate_limit, row_dict

MAX_FEEDBACK = 2000

TYPES = ("bug", "suggestion", "other")


def _uid(c, handler):
    return resolve_token(c, handler.headers.get("Authorization", ""))


def _parse_body(h):
    try:
        raw = h.rfile.read(int(h.headers.get("Content-Length") or 0))
        return json.loads(raw.decode("utf-8") or "{}")
    except Exception:
        return {}


def _handle_feedback(self, c, u, api, method):
    if api == "/feedback" and method == "POST":
        uid = _uid(c, self)
        if not uid:
            self._err(401, "未登录")
            return True
        if not rate_limit(self, "feedback"):
            self._err(429, "操作过于频繁，请稍后再试")
            return True
        body = _parse_body(self)
        ftype = (body.get("type") or "other").strip()
        if ftype not in TYPES:
            ftype = "other"
        content = (body.get("content") or "").strip()
        if not content:
            self._err(400, "反馈内容不能为空")
            return True
        if len(content) > MAX_FEEDBACK:
            self._err(400, "反馈内容过长（≤%d 字）" % MAX_FEEDBACK)
            return True
        contact = (body.get("contact") or "").strip()[:100]
        now = time.time()
        fid = uuid.uuid4().hex
        c.execute(
            "INSERT INTO community_feedback(id,user_id,type,content,contact,status,reply,created,updated)"
            " VALUES(?,?,?,?,?,0,'',?,?)",
            (fid, uid, ftype, content, contact, now, now))
        c.commit()
        self._ok({"id": fid})
        return True

    if api == "/feedback/mine" and method == "GET":
        uid = _uid(c, self)
        if not uid:
            self._err(401, "未登录")
            return True
        rows = c.execute(
            "SELECT * FROM community_feedback WHERE user_id=? ORDER BY created DESC LIMIT 50",
            (uid,)).fetchall()
        out = []
        for r in rows:
            d = row_dict(r)
            out.append({"id": d["id"], "type": d["type"], "content": d["content"],
                        "contact": d.get("contact", ""), "status": d.get("status", 0),
                        "reply": d.get("reply", ""), "created": d.get("created", 0)})
        c.commit()
        self._ok({"list": out})
        return True

    return False


def dispatch(self, c, u, api, method):
    handlers = [_handle_feedback]
    for h in handlers:
        if h(self, c, u, api, method):
            return True
    return False
