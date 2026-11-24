#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""流萤社区 · HTTP 传输入口。

职责边界（工业化约束）：
- server.py 只负责 socket、HTTP 解析、请求体读取、CORS 和响应写回；
- 业务路由、请求级事务、日志、健康检查全部在 app.py / core / routes.py；
- 新增接口不要直接写进本文件，按 routes.py 的领域清单落到 handlers/<domain>.py。
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.path.dirname(os.path.abspath(__file__))
if BASE not in sys.path:
    sys.path.insert(0, BASE)

from app import Application
from core.logging import configure_logging, get_logger
from core.settings import settings
from core.security import (allowed_origins, cors_headers, security_headers,
                           request_is_secure)

HOST = settings.host
PORT = settings.port
API_PREFIX = settings.api_prefix

_APP = Application(settings)
_LOG = get_logger("server")


TRUSTED_PROXIES = ("127.0.0.1/32", "::1/128")


def _cors_allowlist():
    raw = os.environ.get(
        "COMMUNITY_ALLOWED_ORIGINS",
        "https://www.dbmt999.asia,https://dbmt999.asia,https://www.yosar.cloud,https://yosar.cloud")
    return allowed_origins([x.strip() for x in raw.split(",") if x.strip()])


_ALLOWED_ORIGINS = _cors_allowlist()


class Handler(BaseHTTPRequestHandler):
    server_version = "LiuyingCommunity/1.0"
    protocol_version = "HTTP/1.1"

    def version_string(self):
        # 不回显 Python/框架版本，减少指纹。
        return "liuying"

    # ---------- 响应 ----------
    def _send(self, code, obj, ctype="application/json; charset=utf-8"):
        body = obj if isinstance(obj, bytes) else json.dumps(
            obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self._status_code = code
        self._responded = True
        try:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for k, v in cors_headers(self.headers.get("Origin", ""), _ALLOWED_ORIGINS).items():
                self.send_header(k, v)
            secure = request_is_secure(self.headers, self.client_address[0] if self.client_address else "", TRUSTED_PROXIES)
            for k, v in security_headers(is_html=ctype.startswith("text/html"), secure=secure).items():
                self.send_header(k, v)
            rid = getattr(self, "_request_id", "")
            if rid:
                self.send_header(settings.request_id_header, rid)
            self.end_headers()
            if body and not getattr(self, "_head_only", False):
                self.wfile.write(body)
        except Exception:
            pass

    def _err(self, code, msg):
        self._send(code, {"ok": False, "error": msg})

    def _ok(self, data=None, msg="ok"):
        out = {"ok": True, "msg": msg}
        if data is not None:
            out.update(data)
        self._send(200, out)

    # ---------- 请求体 ----------
    def _drain_body(self):
        """兜底消费未读请求体，避免污染 HTTP/1.1 的下一个请求。"""
        try:
            n = int(getattr(self, "_body_remaining", 0) or 0)
            if n > 0:
                self.rfile.read(n)
            self._body_remaining = 0
        except Exception:
            pass

    def _json_body(self, max_len=None):
        max_len = settings.max_json_body if max_len is None else max_len
        length = int(self.headers.get("Content-Length", 0) or 0)
        self._body_remaining = max(0, getattr(self, "_body_remaining", 0))
        if length <= 0:
            return {}
        if length > max_len:
            return None
        try:
            raw = self.rfile.read(length)
            self._body_remaining = max(0, self._body_remaining - len(raw))
            return json.loads(raw.decode("utf-8") or "{}")
        except Exception:
            return {}

    def _multipart(self, max_len=None):
        """简易 multipart 解析：返回 (fields, files)。files: {name: (fname, bytes)}。"""
        max_len = settings.max_upload_body if max_len is None else max_len
        length = int(self.headers.get("Content-Length", 0) or 0)
        if length <= 0:
            return {}, {}
        if length > max_len:
            return None, None
        ctype = self.headers.get("Content-Type", "")
        boundary = None
        for part in ctype.split(";"):
            part = part.strip()
            if part.startswith("boundary="):
                boundary = part[len("boundary="):].strip().strip('"')
        if not boundary:
            return None, None
        raw = self.rfile.read(length)
        self._body_remaining = max(0, getattr(self, "_body_remaining", 0) - len(raw))
        delim = ("--" + boundary).encode()
        fields, files = {}, {}
        for chunk in raw.split(delim):
            if not chunk or chunk[:2] == b"--":
                continue
            head, _, body = chunk.partition(b"\r\n\r\n")
            if not head:
                continue
            if body.endswith(b"\r\n"):
                body = body[:-2]
            headers = {}
            for line in head.decode("utf-8", "ignore").split("\r\n"):
                if ":" in line:
                    k, v = line.split(":", 1)
                    headers[k.strip().lower()] = v.strip()
            cd = headers.get("content-disposition", "")
            name = ""
            fname = ""
            for seg in cd.split(";"):
                seg = seg.strip()
                if seg.startswith("name="):
                    name = seg[len("name="):].strip().strip('"')
                if seg.startswith("filename="):
                    fname = seg[len("filename="):].strip().strip('"')
            if fname:
                files[name] = (fname, body)
            else:
                fields[name] = body.decode("utf-8", "ignore")
        return fields, files

    def _authed(self, c):
        return resolve_uid(c, self.headers.get("Authorization", ""))

    # ---------- CORS ----------
    def do_OPTIONS(self):
        origin = self.headers.get("Origin", "")
        allow = cors_headers(origin, _ALLOWED_ORIGINS)
        # 有 Origin 但不在白名单：拒绝预检，避免任意站点带自定义头跨域调用。
        if origin and not allow:
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(204)
        for k, v in allow.items():
            self.send_header(k, v)
        self.send_header("Content-Length", "0")
        self.end_headers()

    # ---------- 路由 ----------
    def do_GET(self):
        self._route("GET")

    def do_HEAD(self):
        # HEAD 只取响应头：下载入口 / 网关探测依赖它来确定 302 与文件元信息。
        # 路由仍复用 GET 的语义，但响应层不写 body。
        self._route("HEAD")

    def do_POST(self):
        self._route("POST")

    def do_PUT(self):
        self._route("PUT")

    def do_DELETE(self):
        self._route("DELETE")

    def _route(self, method):
        self._head_only = method == "HEAD"
        if self.headers.get("Transfer-Encoding"):
            self._send(400, {"ok": False, "error": "transfer_encoding_not_supported"})
            return
        lengths = self.headers.get_all("Content-Length") or []
        if len(lengths) > 1:
            self._send(400, {"ok": False, "error": "duplicate_content_length"})
            return
        try:
            self._body_remaining = int(self.headers.get("Content-Length", 0) or 0)
        except Exception:
            self._body_remaining = 0
        try:
            _APP.handle(self, method)
        finally:
            self._drain_body()

    def log_message(self, fmt, *args):
        # 访问日志由 app.py 统一输出；这里不再重复写 stderr。
        pass


def resolve_uid(c, auth):
    from common import resolve_token
    return resolve_token(c, auth)


class _Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    configure_logging(settings.log_level, settings.log_json)
    from schema import init_schema
    init_schema()
    try:
        from ai_bot_worker import start as start_ai_bot
        start_ai_bot()
        _LOG.info("ai_bot_worker_started", extra={"event": "ai_bot_worker_started"})
    except Exception:
        _LOG.exception("ai_bot_worker_start_failed",
                       extra={"event": "ai_bot_worker_start_failed"})
    srv = _Server((HOST, PORT), Handler)
    _LOG.info(
        "service_started",
        extra={
            "event": "service_started",
            "host": HOST,
            "port": PORT,
            "version": settings.version,
            "instance": settings.instance_id,
            "api_prefix": settings.api_prefix,
        },
    )
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
        _LOG.info("service_stopped", extra={"event": "service_stopped"})


if __name__ == "__main__":
    main()
