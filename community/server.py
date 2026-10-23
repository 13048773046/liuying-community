#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""流萤社区 · 独立社区服务入口（零侵入：不改音乐任何代码/表/服务）。

部署：systemd community.service，监听 127.0.0.1:8790；
Nginx 追加 location /community/ 反代，与原 music.service 并存。
环境变量：COMMUNITY_DB（默认 /www/wwwroot/music/tracks.db）、
           COMMUNITY_HOST（默认 127.0.0.1）、COMMUNITY_PORT（默认 8790）。
"""
import os
import sys
import json
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.path.dirname(os.path.abspath(__file__))
if BASE not in sys.path:
    sys.path.insert(0, BASE)

HOST = os.environ.get("COMMUNITY_HOST", "127.0.0.1")
PORT = int(os.environ.get("COMMUNITY_PORT", "8790"))

from common import db, client_ip, rate_limit
from handlers import content as H_CONTENT
from handlers import feed as H_FEED
from handlers import user as H_USER
from handlers import official as H_OFFICIAL
from handlers import upload as H_UPLOAD
from handlers import admin_api as H_ADMIN
from handlers import ws as H_WS

API_PREFIX = "/community/api"


class Handler(BaseHTTPRequestHandler):
    server_version = "LiuyingCommunity/1.0"
    protocol_version = "HTTP/1.1"

    # ---------- 工具 ----------
    def _send(self, code, obj, ctype="application/json; charset=utf-8"):
        body = obj if isinstance(obj, bytes) else json.dumps(
            obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, X-Community-Admin-Token, Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.end_headers()
        try:
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

    def _json_body(self, max_len=1024 * 1024):
        length = int(self.headers.get("Content-Length", 0))
        if length <= 0:
            return {}
        if length > max_len:
            return None
        try:
            return json.loads(self.rfile.read(length).decode("utf-8") or "{}")
        except Exception:
            return {}

    def _multipart(self, max_len=64 * 1024 * 1024):
        """简易 multipart 解析：返回 (fields, files)。files: {name: (fname, bytes)}。"""
        length = int(self.headers.get("Content-Length", 0))
        if length <= 0:
            return {}, {}
        if length > max_len:
            return None, None
        ctype = self.headers.get("Content-Type", "")
        m = None
        for part in ctype.split(";"):
            part = part.strip()
            if part.startswith("boundary="):
                m = part[len("boundary="):].strip().strip('"')
        if not m:
            return None, None
        raw = self.rfile.read(length)
        delim = ("--" + m).encode()
        fields = {}
        files = {}
        for chunk in raw.split(delim):
            if not chunk or chunk[:2] == b"--":
                continue
            head, _, body = chunk.partition(b"\r\n\r\n")
            if not head:
                continue
            # 去尾 \r\n
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
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, X-Community-Admin-Token, Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.send_header("Content-Length", "0")
        self.end_headers()

    # ---------- 路由 ----------
    def do_GET(self):
        self._route("GET")

    def do_POST(self):
        self._route("POST")

    def do_PUT(self):
        self._route("PUT")

    def do_DELETE(self):
        self._route("DELETE")

    def _route(self, method):
        u = urllib.parse.urlparse(self.path)
        path = u.path
        if not path.startswith(API_PREFIX):
            if path == "/health":
                self._send(200, {"ok": True, "service": "community", "ts": time.time()})
                return
            # H5 静态页（admin 后台 / 分享落地页）：支持裸路径（本地/测试）与 /community 前缀（Nginx 代理后）
            sp = path[10:] if path.startswith("/community/") else path
            if sp in ("/admin.html", "/share.html"):
                fname = os.path.join(BASE, "templates", sp.lstrip("/"))
                if os.path.exists(fname):
                    with open(fname, "rb") as f:
                        data = f.read()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
            self._err(404, "not found")
            return
        api = path[len(API_PREFIX):] or "/"
        if api == "/health":
            self._send(200, {"ok": True, "service": "community", "ts": time.time()})
            return
        try:
            c = db()
            try:
                handled = self._dispatch(method, c, u, api)
                if not handled:
                    self._err(404, "api not found: " + api)
            finally:
                c.close()
        except Exception as e:
            import traceback
            traceback.print_exc()
            try:
                self._err(500, "server error")
            except Exception:
                pass

    def _dispatch(self, method, c, u, api):
        # 路由表：按模块分发
        for mod in (H_CONTENT, H_FEED, H_USER, H_OFFICIAL, H_UPLOAD, H_ADMIN, H_WS):
            try:
                handled = mod.dispatch(self, c, u, api, method)
                if handled:
                    return True
            except Exception as e:
                import traceback
                traceback.print_exc()
                self._err(500, "server error: %s" % e)
                return True
        return False

    def log_message(self, fmt, *args):
        pass


def resolve_uid(c, auth):
    from common import resolve_token
    return resolve_token(c, auth)


def main():
    from schema import init_schema
    init_schema()
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    srv.daemon_threads = True
    print("Liuying Community service on %s:%d, db=%s" % (HOST, PORT, os.environ.get("COMMUNITY_DB", "/www/wwwroot/music/tracks.db")), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
