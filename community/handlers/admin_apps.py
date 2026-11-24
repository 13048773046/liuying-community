# -*- coding: utf-8 -*-
"""主服务薄路由：应用市场管理 API（审核/分类/评论/举报）。"""
import re
import urllib.parse

from common import admin_log, notify
from app_market import service
from handlers.admin_api import _authed, _body


def _auth(self, c):
    return _authed(c, self)


def _notify_submitter(c, app_id, title, content):
    """通知失败不能影响审核结果（共享 notifications 表由主业务维护）。"""
    try:
        row = c.execute("SELECT submitter_id FROM community_apps WHERE id=?", (app_id,)).fetchone()
        if row and row[0]:
            notify(c, row[0], "community_app", title, content)
    except Exception:
        pass


def _handle_apps(self, c, u, api, method, adm):
    if api == "/admin/apps/stats":
        counts = {str(s): 0 for s in (0, 1, 2, 3, 4)}
        for st, cnt in c.execute("SELECT status,COUNT(*) FROM community_apps GROUP BY status"):
            counts[str(st)] = cnt
        self._ok({"stats": counts})
        return True
    if api == "/admin/apps" and method == "GET":
        data = service.admin_list(c, u.query)
        self._ok(data)
        return True
    m = re.match(r"^/admin/apps/([A-Za-z0-9_-]+)(?:/(.+))?$", api)
    if not m:
        return False
    aid, rest = m.group(1), (m.group(2) or "")
    if not rest and method == "GET":
        data, err = service.admin_detail(c, aid)
        if err:
            self._err(404, err)
            return True
        self._ok({"app": data})
        return True
    if rest == "review" and method == "POST":
        body = _body(self)
        data, err = service.review(c, aid, body.get("versionId") or "", body.get("action") or "",
                                   body.get("reason") or "", adm[0])
        if err:
            self._err(400, err)
            return True
        if data.get("action") == "approved":
            _notify_submitter(c, aid, "应用审核通过", "你的应用已通过审核并上架")
        else:
            _notify_submitter(c, aid, "应用审核未通过", "你的应用未通过审核：" +
                              str(body.get("reason") or "")[:120])
        admin_log(c, adm[0], "app_review", "app", aid, str(data.get("action")))
        try:
            import ai_bot_core as _AIB
            _AIB.on_app_reviewed(c, aid, data.get("action") == "approved")
        except Exception:
            pass
        c.commit()
        self._ok(data)
        return True
    if rest == "state" and method == "POST":
        body = _body(self)
        data, err = service.set_app_state(c, aid, body.get("action") or "", adm[0])
        if err:
            self._err(400, err)
            return True
        admin_log(c, adm[0], "app_state", "app", aid, str(body.get("action") or ""))
        c.commit()
        self._ok(data)
        return True
    return False


def _handle_categories(self, c, u, api, method, adm):
    if api == "/admin/app-categories" and method == "GET":
        self._ok(service.admin_categories(c))
        return True
    if api == "/admin/app-categories" and method == "POST":
        data, err = service.admin_category_create(c, _body(self))
        if err:
            self._err(400, err)
            return True
        admin_log(c, adm[0], "app_category_create", "app_category", "", "")
        c.commit()
        self._ok(data)
        return True
    m = re.match(r"^/admin/app-categories/([A-Za-z0-9_-]+)$", api)
    if m and method == "PUT":
        data, err = service.admin_category_update(c, m.group(1), _body(self))
        if err:
            self._err(400, err)
            return True
        admin_log(c, adm[0], "app_category_update", "app_category", m.group(1), "")
        c.commit()
        self._ok(data)
        return True
    if m and method == "DELETE":
        data, err = service.admin_category_delete(c, m.group(1))
        if err:
            self._err(400, err)
            return True
        admin_log(c, adm[0], "app_category_delete", "app_category", m.group(1), "")
        c.commit()
        self._ok(data)
        return True
    return False


def _handle_comments(self, c, u, api, method, adm):
    if api == "/admin/app-comments" and method == "GET":
        self._ok(service.admin_comments(c, u.query))
        return True
    m = re.match(r"^/admin/app-comments/([A-Za-z0-9_-]+)$", api)
    if m and method == "POST":
        body = _body(self)
        data, err = service.admin_comment_state(c, m.group(1), body.get("action") or "")
        if err:
            self._err(400, err)
            return True
        admin_log(c, adm[0], "app_comment_state", "app_comment", m.group(1),
                  str(body.get("action") or ""))
        c.commit()
        self._ok(data)
        return True
    return False


def _handle_reports(self, c, u, api, method, adm):
    if api == "/admin/app-reports" and method == "GET":
        q = {k: (v[0] if v else "") for k, v in urllib.parse.parse_qs(u.query).items()}
        self._ok(service.admin_app_reports(c, int(q.get("status") or 0)))
        return True
    m = re.match(r"^/admin/app-reports/([A-Za-z0-9_-]+)/handle$", api)
    if m and method == "POST":
        body = _body(self)
        action = (body.get("action") or "ignore").strip()
        row = c.execute("SELECT * FROM community_reports WHERE id=? AND target_type='app'",
                        (m.group(1),)).fetchone()
        if not row:
            self._err(404, "举报不存在")
            return True
        result = "已忽略"
        if action == "offline":
            data, err = service.set_app_state(c, row["target_id"], "offline", adm[0])
            if err:
                self._err(400, err)
                return True
            result = "已下架应用"
        c.execute("UPDATE community_reports SET status=1,result=? WHERE id=?",
                  (result, m.group(1)))
        admin_log(c, adm[0], "app_report_handle", "app", row["target_id"], result)
        c.commit()
        self._ok({"result": result})
        return True
    return False


def dispatch(self, c, u, api, method):
    if not (api.startswith("/admin/apps") or api.startswith("/admin/app-categories") or
            api.startswith("/admin/app-comments") or api.startswith("/admin/app-reports")):
        return False
    adm = _auth(self, c)
    if not adm:
        return True
    for h in (_handle_apps, _handle_categories, _handle_comments, _handle_reports):
        if h(self, c, u, api, method, adm):
            return True
    return False
