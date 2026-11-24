# -*- coding: utf-8 -*-
"""官网内容：公开读取 + 管理端编辑。"""
from handlers.admin_api import _authed, _body
import site_content as SITE


def dispatch(self, c, u, api, method):
    if api == "/site/content" and method == "GET":
        self._ok({"content": SITE.get_content(c)})
        return True
    if not api.startswith("/admin/site/"):
        return False
    adm = _authed(c, self)
    if not adm:
        return True
    if api == "/admin/site/content" and method == "GET":
        self._ok({"content": SITE.get_content(c)})
        return True
    if api == "/admin/site/content" and method == "POST":
        body = _body(self)
        try:
            content = SITE.set_content(body.get("content") if isinstance(body.get("content"), dict) else body)
        except Exception as e:
            self._err(400, str(e)[:300])
            return True
        self._ok({"content": content, "msg": "官网内容已保存"})
        return True
    if api == "/admin/site/content" and method == "DELETE":
        c.execute("DELETE FROM site_config WHERE key=?", (SITE.CONFIG_KEY,))
        c.commit()
        self._ok({"content": SITE.get_content(c), "msg": "已恢复默认内容"})
        return True
    return False
