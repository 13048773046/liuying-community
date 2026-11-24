# -*- coding: utf-8 -*-
"""流小萤 · 公开资料 / 管理端 AI 运营接口。"""
import json
import re
import urllib.parse

import ai_bot_core as CORE
import ai_bot_dm as DM
import ai_bot_worker as WORKER
from handlers.admin_api import _authed, _body


def _public(self, c, api, method):
    if api == "/ai-bot/profile" and method == "GET":
        u = CORE.bot_user(c)
        if not u:
            self._err(404, "AI 账号不存在")
            return True
        p = CORE.get_policy(c)
        self._ok({"bot": {
            "id": u.get("id"), "name": u.get("name"), "avatar": u.get("avatar"),
            "signature": u.get("signature"), "title": u.get("title"),
            "verified": u.get("verified"), "verifiedLabel": u.get("verified_label"),
        }, "enabled": bool(p.get("enabled")), "autoPublish": bool(p.get("auto_publish")),
           "autoEngage": bool(p.get("auto_engage"))})
        return True
    return False


def _admin(self, c, u, api, method):
    if api == "/admin/ai-bot/status" and method == "GET":
        self._ok(CORE.admin_stats())
        return True
    if api == "/admin/ai-bot/policy" and method == "GET":
        self._ok({"policy": CORE.get_policy(c)})
        return True
    if api == "/admin/ai-bot/policy" and method == "POST":
        body = _body(self)
        try:
            p = CORE.set_policy(body.get("policy") if isinstance(body.get("policy"), dict) else body)
        except Exception as e:
            self._err(400, str(e)[:200])
            return True
        self._ok({"policy": p})
        return True
    if api == "/admin/ai-bot/actions" and method == "GET":
        q = urllib.parse.parse_qs(u.query)
        page = max(1, int((q.get("page") or ["1"])[0] or 1))
        size = min(100, max(1, int((q.get("size") or ["30"])[0] or 30)))
        kind = (q.get("kind") or [""])[0].strip()
        status = (q.get("status") or [""])[0].strip()
        where, args = [], []
        if kind:
            where.append("kind LIKE ?")
            args.append(kind + "%")
        if status:
            where.append("status=?")
            args.append(status)
        sql = "SELECT * FROM ai_bot_actions"
        if where:
            sql += " WHERE " + " AND ".join(where)
        rows = c.execute(sql + " ORDER BY created DESC LIMIT ? OFFSET ?",
                         args + [size, (page - 1) * size]).fetchall()
        total = c.execute("SELECT COUNT(*) FROM ai_bot_actions" +
                          (" WHERE " + " AND ".join(where) if where else ""), args).fetchone()[0]
        out = []
        for r in rows:
            d = dict(r)
            d["detail"] = (d.get("detail") or "")[:300]
            out.append(d)
        self._ok({"list": out, "total": total, "page": page, "size": size})
        return True
    m = re.match(r"^/admin/ai-bot/run$", api)
    if m and method == "POST":
        body = _body(self)
        kind = (body.get("kind") or "all").strip().lower()
        if kind not in ("all", "post", "video", "app", "engage", "followback", "dm"):
            self._err(400, "未知任务类型")
            return True
        if kind == "dm":
            import threading
            threading.Thread(target=DM.process_unread, daemon=True).start()
            self._ok({"started": True, "kind": "dm"})
            return True
        if kind == "all":
            for k in ("followback", "engage", "post", "video", "app"):
                WORKER.run_now(k)
            self._ok({"started": True, "kind": "all"})
            return True
        self._ok(WORKER.run_now(kind))
        return True
    return False


def dispatch(self, c, u, api, method):
    if api.startswith("/ai-bot/"):
        return _public(self, c, api, method)
    if not api.startswith("/admin/ai-bot/"):
        return False
    adm = _authed(c, self)
    if not adm:
        return True
    return _admin(self, c, u, api, method)
