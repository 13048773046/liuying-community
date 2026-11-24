# -*- coding: utf-8 -*-
"""应用层：把 HTTP 传输与业务分发解耦。

Handler 只负责读写 socket；这里负责：
- 请求 ID / 访问日志 / 耗时 / 状态码；
- health / ready / version 与 H5 静态页；
- 请求级数据库连接与事务；
- 模块路由、统一异常与 404。

业务 handler 的 `dispatch(self, c, u, api, method)` 协议保持不变，便于渐进式重构。
"""
from __future__ import annotations

import html as html_lib
import json
import os
import re
import time
import urllib.parse
import uuid
from typing import Any

from core.db import check_ready, request_connection
from core.errors import ApiError, error_payload
from core.logging import get_logger, set_request_id
from core.router import Router
from core.settings import Settings, settings as default_settings
from routes import MODULES

_STATIC_PAGES = ("admin.html", "share.html", "admin-apps.html")
_APP_SHARE_RE = re.compile(r"^/community/app/([A-Za-z0-9_-]{16,64})/?$")


class Application:
    def __init__(self, settings: Settings | None = None, modules=None):
        self.settings = settings or default_settings
        self.router = Router(MODULES if modules is None else modules)
        self.started_at = time.time()
        self.log = get_logger("app")

    # ---------- 对外入口 ----------
    def handle(self, handler: Any, method: str) -> None:
        parsed = urllib.parse.urlparse(handler.path)
        path = parsed.path or "/"
        query = parsed.query
        request_id = self._request_id(handler)
        handler._request_id = request_id
        set_request_id(request_id)
        start = time.perf_counter()
        module_name = None
        status = 0
        uid = ""
        try:
            status = self._handle_path(handler, method, path, parsed, query)
        except ApiError as exc:
            self.log.warning(
                "api_error", extra={"event": "api_error", "request_id": request_id,
                                    "path": path, "status": exc.status, "code": exc.code,
                                    "error": exc.message},
            )
            status = self._safe_error(handler, exc.status, exc.message, exc.code)
        except Exception as exc:  # 兜底：任何未预期异常都不能让进程/连接悬空
            self.log.exception(
                "unhandled_error", extra={"event": "unhandled_error", "request_id": request_id,
                                           "path": path, "method": method},
            )
            status = self._safe_error(handler, 500, "server error", "internal_error")
            _ = exc
        finally:
            try:
                handler._drain_body()
            except Exception:
                pass
            duration_ms = round((time.perf_counter() - start) * 1000, 2)
            module_name = getattr(handler, "_module_name", None)
            uid = getattr(handler, "_uid", "") or ""
            self.log.info(
                "http_request",
                extra={
                    "event": "http_request",
                    "request_id": request_id,
                    "method": method,
                    "path": path,
                    "status": status,
                    "duration_ms": duration_ms,
                    "ip": _client_ip(handler),
                    "uid": uid,
                    "route": module_name,
                },
            )

    # ---------- 路径分派 ----------
    def _handle_path(self, handler: Any, method: str, path: str, parsed, query: str) -> int:
        if path in ("/health", self.settings.api_health):
            self._json(handler, 200, {
                "ok": True,
                "service": self.settings.service_name,
                "status": "alive",
                "instance": self.settings.instance_id,
                "ts": time.time(),
            })
            return 200
        if path in ("/ready", self.settings.api_ready):
            ready = check_ready()
            self._json(handler, 200 if ready else 503, {
                "ok": ready,
                "service": self.settings.service_name,
                "status": "ready" if ready else "not_ready",
                "instance": self.settings.instance_id,
                "ts": time.time(),
            })
            return 200 if ready else 503
        if path in ("/version", self.settings.api_version):
            self._json(handler, 200, {
                "ok": True,
                "service": self.settings.service_name,
                "version": self.settings.version,
                "apiPrefix": self.settings.api_prefix,
                "instance": self.settings.instance_id,
                "uptimeSeconds": int(time.time() - self.started_at),
            })
            return 200

        if path.startswith("/community/app/"):
            if self._serve_app_share(handler, path):
                return getattr(handler, "_status_code", 0) or 200

        if path == "/invite" or path.startswith("/invite/"):
            if self._serve_invite(handler, path):
                return 200
            self._json(handler, 404, error_payload("not found", "not_found"))
            return 404

        if not path.startswith(self.settings.api_prefix):
            if self._serve_static(handler, path):
                return 200
            self._json(handler, 404, error_payload("not found", "not_found"))
            return 404

        api = path[len(self.settings.api_prefix):] or "/"
        if api == "/":
            self._json(handler, 404, error_payload("api not found: /", "route_not_found"))
            return 404

        with request_connection() as c:
            # 统一日志的 uid 只用于排障；无 Authorization 时不查库。
            uid = _resolve_uid(c, handler)
            handler._uid = uid
            module_name = self.router.dispatch(handler, c, parsed, api, method)
            handler._module_name = module_name
            if module_name is None:
                if not getattr(handler, "_responded", False):
                    self._json(handler, 404, error_payload("api not found: " + api, "route_not_found"))
                    return 404
                return getattr(handler, "_status_code", 0) or 0
            return getattr(handler, "_status_code", 0) or 200

    # ---------- 响应 / 静态页 ----------
    def _json(self, handler: Any, status: int, obj: dict) -> None:
        handler._send(status, obj)

    def _safe_error(self, handler: Any, status: int, message: str, code: str) -> int:
        if getattr(handler, "_responded", False):
            return getattr(handler, "_status_code", 0) or status
        try:
            handler._send(status, error_payload(message, code))
        except Exception:
            pass
        return status

    # ---------- 应用分享落地页 ----------
    def _serve_app_share(self, handler: Any, path: str) -> bool:
        """GET /community/app/{id} → 服务端渲染的应用分享页。

        分享页不是 API：需要 OG 预览、静态可抓取，所以在这里直接用应用市场的
        公开字段填充模板，页面内的交互（安装/下载）再由前端 JS 接管。
        """
        m = _APP_SHARE_RE.match(path)
        if not m:
            return False
        app_id = m.group(1)
        item = None
        try:
            with request_connection() as c:
                row = c.execute(
                    "SELECT * FROM community_apps WHERE id=? AND status=2", (app_id,)
                ).fetchone()
                if row:
                    from app_market import service as app_service
                    item = app_service._public_item(c, row, detail=True)
        except Exception:
            item = None
        base = self.settings.public_origin
        if not item:
            body = (
                '<!DOCTYPE html><html lang="zh-CN"><meta charset="utf-8">'
                '<meta name="viewport" content="width=device-width,initial-scale=1">'
                '<title>应用不存在 · 流萤社区</title>'
                '<body style="margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;'
                'background:#06110e;color:#f4f1e8;font:15px/1.7 -apple-system,\'PingFang SC\',sans-serif">'
                '<div style="text-align:center;padding:30px"><div style="font-size:44px;opacity:.35">萤</div>'
                '<p style="color:rgba(244,241,232,.55)">应用不存在或已下架</p>'
                '<p><a href="/community/" style="color:#45e0ae;text-decoration:none">回社区看看 →</a></p></div></body></html>'
            )
            handler._send(404, body.encode("utf-8"), "text/html; charset=utf-8")
            return True
        fname = os.path.join(self.settings.templates_dir, "app-share.html")
        if not os.path.isfile(fname):
            return False
        try:
            with open(fname, "r", encoding="utf-8") as f:
                tpl = f.read()
        except OSError:
            return False
        icon = (item.get("icon") or "").strip()
        if icon.startswith("http://") or icon.startswith("https://"):
            icon_url = icon
        elif icon:
            icon_url = base + (icon if icon.startswith("/")
                               else "/community/api/media/" + urllib.parse.quote(icon))
        else:
            icon_url = base + "/community/static/favicon.svg"
        page_url = "%s/community/app/%s" % (base, app_id)
        desc = (item.get("shareReason") or item.get("description") or "来自流萤社区应用市场").strip()
        desc = re.sub(r"\s+", " ", desc)[:110]
        payload = {
            "app": item,
            "shareUrl": page_url,
            "siteUrl": base,
        }
        app_json = json.dumps(payload, ensure_ascii=False, separators=(",", ":")) \
            .replace("<", "\\u003c").replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")
        values = {
            "{{OG_TITLE}}": html_lib.escape("%s v%s · 流萤社区应用分享" % (
                item.get("name") or "应用", item.get("version") or "")),
            "{{OG_DESC}}": html_lib.escape(desc, quote=True),
            "{{OG_IMAGE}}": html_lib.escape(icon_url, quote=True),
            "{{OG_URL}}": html_lib.escape(page_url, quote=True),
            "{{APP_JSON}}": app_json,
        }
        for key, value in values.items():
            tpl = tpl.replace(key, value)
        handler._send(200, tpl.encode("utf-8"), "text/html; charset=utf-8")
        return True

    def _serve_invite(self, handler: Any, path: str) -> bool:
        rel = path[len("/invite/"):] if path.startswith("/invite/") else ""
        rel = rel or "index.html"
        if rel.endswith("/"):
            rel += "index.html"
        rel = urllib.parse.unquote(rel)
        if ".." in rel or rel.startswith("/"):
            return False
        base = os.path.abspath(os.path.join(self.settings.templates_dir, "invite"))
        fname = os.path.abspath(os.path.join(base, rel))
        if not fname.startswith(base + os.sep) or not os.path.isfile(fname):
            return False
        ext = os.path.splitext(fname)[1].lower()
        ctype = {
            ".html": "text/html; charset=utf-8",
            ".css": "text/css; charset=utf-8",
            ".js": "application/javascript; charset=utf-8",
            ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
            ".webp": "image/webp", ".svg": "image/svg+xml",
            ".json": "application/json; charset=utf-8",
            ".wasm": "application/wasm",
            ".ico": "image/x-icon", ".woff2": "font/woff2",
        }.get(ext, "application/octet-stream")
        try:
            with open(fname, "rb") as f:
                data = f.read()
        except OSError:
            return False
        handler._send(200, data, ctype)
        return True

    def _serve_static(self, handler: Any, path: str) -> bool:
        sp = path[10:] if path.startswith("/community/") else path
        name = sp.lstrip("/")
        if name not in _STATIC_PAGES:
            return False
        fname = os.path.join(self.settings.templates_dir, name)
        if not os.path.isfile(fname):
            return False
        try:
            with open(fname, "rb") as f:
                data = f.read()
        except OSError:
            return False
        handler._send(200, data, "text/html; charset=utf-8")
        return True

    # ---------- 请求元数据 ----------
    def _request_id(self, handler: Any) -> str:
        raw = (handler.headers.get(self.settings.request_id_header) or "").strip()
        if raw and len(raw) <= 64 and all(ch.isalnum() or ch in "._-" for ch in raw):
            return raw
        return uuid.uuid4().hex


def _client_ip(handler: Any) -> str:
    try:
        from common import client_ip
        return client_ip(handler)
    except Exception:
        return ""


def _resolve_uid(c: Any, handler: Any) -> str:
    auth = handler.headers.get("Authorization", "")
    if not auth:
        return ""
    try:
        from common import resolve_token
        return str(resolve_token(c, auth) or "")
    except Exception:
        return ""


def build_application(settings: Settings | None = None) -> Application:
    return Application(settings)
