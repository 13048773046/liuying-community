#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""应用市场端到端冒烟：主服务 + resolver + gateway，全部走真实 HTTP。

运行：python3 community/tests/app_market_smoke.py
它会创建临时数据库 /tmp/app_market_smoke.db，并在 8800/8890/8891/8892 起测试进程。
"""
import base64
import http.client
import json
import os
import shutil
import signal
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid
from http.server import ThreadingHTTPServer

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(BASE)
sys.path.insert(0, BASE)

DB = "/tmp/app_market_smoke.db"
PORT = 8800
RESOLVER_PORT = 8890
GATEWAY_PORT = 8891
SOURCE_PORT = 8899
TOKEN = "tok_app_smoke"
ADMIN = "adm_app_smoke"
SECRET = "smoke-ticket-secret"
INTERNAL = "smoke-internal-token"

PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")




SOURCE_BYTES = (b"APK-SMOKE-TEST\n" * (5242880 // 15 + 1))[:5242880]


class SourceHandler(__import__("http.server", fromlist=["BaseHTTPRequestHandler"]).BaseHTTPRequestHandler):
    """测试用源站：支持 HEAD 与 Range，模拟真实 APK 直链。"""

    protocol_version = "HTTP/1.1"

    def _headers(self, code, length):
        self.send_response(code)
        self.send_header("Content-Type", "application/vnd.android.package-archive")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        self.end_headers()

    def do_HEAD(self):
        self._headers(200, len(SOURCE_BYTES))

    def do_GET(self):
        rng = self.headers.get("Range", "")
        m = __import__("re").match(r"bytes=(\d+)-(\d*)", rng)
        if m:
            start = int(m.group(1))
            end = int(m.group(2)) if m.group(2) else len(SOURCE_BYTES) - 1
            end = min(end, len(SOURCE_BYTES) - 1)
            body = SOURCE_BYTES[start:end + 1]
            self.send_response(206)
            self.send_header("Content-Type", "application/vnd.android.package-archive")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, len(SOURCE_BYTES)))
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self._headers(200, len(SOURCE_BYTES))
        self.wfile.write(SOURCE_BYTES)

    def log_message(self, fmt, *args):
        pass


def req(method, path, body=None, token=None, admin=None, headers=None):
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=20)
    h = dict(headers or {})
    if body is not None:
        h["Content-Type"] = "application/json"
    if token:
        h["Authorization"] = "Bearer " + token
    if admin:
        h["X-Community-Admin-Token"] = admin
    conn.request(method, path, body=json.dumps(body, ensure_ascii=False).encode() if body is not None else None, headers=h)
    r = conn.getresponse()
    data = r.read()
    out = json.loads(data.decode() or "{}") if data else {}
    status = r.status
    hdrs = dict(r.getheaders())
    conn.close()
    return status, out, hdrs


def upload_image(name="icon.png"):
    boundary = "----smoke" + uuid.uuid4().hex
    body = (("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%s\"\r\n"
             "Content-Type: image/png\r\n\r\n" % (boundary, name)).encode() + PNG +
            ("\r\n--%s--\r\n" % boundary).encode())
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=20)
    conn.request("POST", "/community/api/upload-image", body=body, headers={
        "Authorization": "Bearer " + TOKEN,
        "Content-Type": "multipart/form-data; boundary=" + boundary,
        "Content-Length": str(len(body)),
    })
    r = conn.getresponse()
    data = json.loads(r.read().decode())
    status = r.status
    conn.close()
    assert status == 200, data
    assert data.get("ok"), data
    return data["url"]


def wait_port(port, path="/health", timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            conn.request("GET", path)
            r = conn.getresponse()
            ok = r.status == 200
            r.read()
            conn.close()
            if ok:
                return
        except Exception:
            pass
        time.sleep(0.2)
    raise RuntimeError("port %s not ready" % port)


def start_proc(cmd, env, log):
    f = open(log, "wb")
    p = subprocess.Popen(cmd, stdout=f, stderr=subprocess.STDOUT, env=env, cwd=ROOT)
    return p, f


def main():
    try:
        os.remove(DB)
    except FileNotFoundError:
        pass
    os.environ.update({
        "COMMUNITY_DB": DB, "COMMUNITY_PORT": str(PORT),
        "APP_TICKET_SECRET": SECRET, "APP_INTERNAL_TOKEN": INTERNAL,
        "APP_ALLOW_PRIVATE": "1",
        "APP_MANIFEST_URL": "http://127.0.0.1:%d/community/api/internal/app-download/manifest" % PORT,
        "APP_RESOLVER_URL": "http://127.0.0.1:%d/resolve" % RESOLVER_PORT,
        "APP_RESOLVER_PORT": str(RESOLVER_PORT), "APP_DELIVERY_PORT": str(GATEWAY_PORT),
    })
    from schema import init_schema
    init_schema()
    # schema 不建 users/tokens，测试单独补最小共享表
    c = sqlite3.connect(DB)
    c.execute("CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY,name TEXT,avatar TEXT,created REAL)")
    c.execute("CREATE TABLE IF NOT EXISTS tokens(token TEXT PRIMARY KEY,user_id TEXT,expires REAL)")
    c.execute("INSERT OR REPLACE INTO users VALUES(?,?,?,?)", ("u_smoke", "冒烟测试用户", "", time.time()))
    c.execute("INSERT OR REPLACE INTO tokens VALUES(?,?,?)", (TOKEN, "u_smoke", time.time() + 3600 * 24))
    c.execute("DELETE FROM community_admins")
    c.execute("INSERT INTO community_admins(token,user_id,level,role,perms,name,created)"
              " VALUES(?,?,?,?,?,?,?)", (ADMIN, "", 1, "super", "apps", "冒烟管理员", time.time()))
    c.commit(); c.close()

    os.environ.update({
        "COMMUNITY_DB": DB, "COMMUNITY_PORT": str(PORT),
        "APP_TICKET_SECRET": SECRET, "APP_INTERNAL_TOKEN": INTERNAL,
        "APP_ALLOW_PRIVATE": "1",
        "APP_MANIFEST_URL": "http://127.0.0.1:%d/community/api/internal/app-download/manifest" % PORT,
        "APP_RESOLVER_URL": "http://127.0.0.1:%d/resolve" % RESOLVER_PORT,
        "APP_RESOLVER_PORT": str(RESOLVER_PORT), "APP_DELIVERY_PORT": str(GATEWAY_PORT),
    })
    # handlers.dm 桩
    import types
    m = types.ModuleType("handlers.dm")
    m.dispatch = lambda *a, **k: False
    sys.modules["handlers.dm"] = m
    import server
    from schema import init_schema
    init_schema()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), server.Handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    source_srv = ThreadingHTTPServer(("127.0.0.1", SOURCE_PORT), SourceHandler)
    threading.Thread(target=source_srv.serve_forever, daemon=True).start()

    procs = []
    try:
        procs.append(start_proc([sys.executable, os.path.join(BASE, "..", "services", "app_resolver", "app.py")],
                                os.environ.copy(), "/tmp/app_market_smoke_resolver.log"))
        procs.append(start_proc([sys.executable, os.path.join(BASE, "..", "services", "app_delivery", "app.py")],
                                os.environ.copy(), "/tmp/app_market_smoke_gateway.log"))
        wait_port(PORT, "/community/api/health")
        wait_port(RESOLVER_PORT)
        wait_port(GATEWAY_PORT)

        # 分类
        st, out, _ = req("GET", "/community/api/apps/categories")
        assert st == 200 and out["ok"] and out["list"], out
        cats = out["list"]
        cat = next(x for x in cats if x["id"] == "appcat_tools")
        sub = cat["children"][0]

        # 上传图标 + 3 张截图
        icon = upload_image()
        shots = [upload_image("shot%d.png" % i) for i in range(3)]
        download = "http://127.0.0.1:%d/sample.apk" % SOURCE_PORT

        payload = {
            "name": "冒烟测试应用", "icon": icon, "packageType": "apk",
            "packageName": "com.liuying.smoke", "categoryId": cat["id"],
            "subcategoryId": sub["id"], "description": "这是一个用于端到端验证应用市场投稿、审核和下载链路的应用。",
            "shareReason": "我想把这款自己常用的小工具分享给社区朋友。",
            "screenshots": shots, "downloadUrl": download, "versionName": "1.0.0",
            "osVersion": "Android 8.0+",
        }
        st, out, _ = req("POST", "/community/api/apps", payload, token=TOKEN)
        assert st == 200 and out["ok"] and out["status"] == 1, out
        app_id, vid = out["id"], out["versionId"]

        # 默认待审
        st, out, _ = req("GET", "/community/api/admin/apps?status=1", admin=ADMIN)
        assert st == 200 and out["total"] >= 1, out
        st, out, _ = req("GET", "/community/api/admin/apps/%s" % app_id, admin=ADMIN)
        assert st == 200 and out["app"]["versions"][0]["status"] == 1, out

        # 通过审核
        st, out, _ = req("POST", "/community/api/admin/apps/%s/review" % app_id,
                         {"versionId": vid, "action": "approve", "reason": ""}, admin=ADMIN)
        assert st == 200 and out["action"] == "approved", out

        # 公开列表 / 详情
        st, out, _ = req("GET", "/community/api/apps")
        assert st == 200 and any(x["id"] == app_id for x in out["list"]), out
        st, out, _ = req("GET", "/community/api/apps/%s" % app_id, token=TOKEN)
        assert st == 200 and out["app"]["version"] == "1.0.0" and len(out["app"]["screenshots"]) == 3, out

        # 公开主页的应用投稿：只展示已上架应用，不暴露投稿状态
        author_id = out["app"]["author"]["id"]
        st, out, _ = req("GET", "/community/api/apps/by-user/%s" % author_id)
        assert st == 200 and out["total"] == 1, out
        assert out["list"][0]["id"] == app_id, out
        assert "status" not in out["list"][0], out
        st, out, _ = req("GET", "/community/api/apps/by-user/u_not_exists")
        assert st == 200 and out["total"] == 0 and out["list"] == [], out

        # 评论
        st, out, _ = req("POST", "/community/api/apps/%s/comments" % app_id, {"content": "冒烟评论"}, token=TOKEN)
        assert st == 200 and out["ok"], out
        cid = out["id"]
        st, out, _ = req("GET", "/community/api/apps/%s/comments" % app_id)
        assert st == 200 and out["total"] == 1, out
        st, out, _ = req("DELETE", "/community/api/apps/%s/comments/%s" % (app_id, cid), token=TOKEN)
        assert st == 200 and out["ok"], out

        # 评分
        st, out, _ = req("POST", "/community/api/apps/%s/rating" % app_id, {"score": 5}, token=TOKEN)
        assert st == 200 and out["score"] == 5 and out["rating"] == 5, out
        st, out, _ = req("GET", "/community/api/apps/%s/rating" % app_id, token=TOKEN)
        assert st == 200 and out["myRating"] == 5, out

        # 收藏
        st, out, _ = req("POST", "/community/api/apps/%s/favorite" % app_id, token=TOKEN)
        assert st == 200 and out["favorited"] and out["favoriteCount"] == 1, out
        st, out, _ = req("GET", "/community/api/apps/mine/favorites", token=TOKEN)
        assert st == 200 and len(out["list"]) == 1, out
        st, out, _ = req("DELETE", "/community/api/apps/%s/favorite" % app_id, token=TOKEN)
        assert st == 200 and not out["favorited"], out

        # 举报 + 后台处理（忽略）
        st, out, _ = req("POST", "/community/api/apps/%s/report" % app_id, {"reason": "冒烟举报原因"}, token=TOKEN)
        assert st == 200 and out["ok"], out
        st, out, _ = req("GET", "/community/api/admin/app-reports?status=0", admin=ADMIN)
        assert st == 200 and out["list"], out
        rid = out["list"][0]["id"]
        st, out, _ = req("POST", "/community/api/admin/app-reports/%s/handle" % rid, {"action": "ignore"}, admin=ADMIN)
        assert st == 200, out

        # 新版本：老版本在线，审核后切换
        v2 = dict(payload)
        v2.update({"versionName": "1.1.0", "downloadUrl": download})
        st, out, _ = req("POST", "/community/api/apps/%s/versions" % app_id, v2, token=TOKEN)
        assert st == 200 and out["status"] == 1, out
        vid2 = out["versionId"]
        st, out, _ = req("GET", "/community/api/apps/%s" % app_id)
        assert st == 200 and out["app"]["version"] == "1.0.0", out
        st, out, _ = req("POST", "/community/api/admin/apps/%s/review" % app_id,
                         {"versionId": vid2, "action": "approve", "reason": ""}, admin=ADMIN)
        assert st == 200, out
        st, out, _ = req("GET", "/community/api/apps/%s" % app_id)
        assert st == 200 and out["app"]["version"] == "1.1.0", out

        # 重复版本号拒绝
        st, out, _ = req("POST", "/community/api/apps/%s/versions" % app_id,
                         dict(v2, versionName="1.0.0"), token=TOKEN)
        assert st == 400 and not out.get("ok"), out

        # 下载 entry -> 302 ticket
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=20)
        conn.request("GET", "/community/api/apps/%s/download" % app_id, headers={"Authorization": "Bearer " + TOKEN})
        r = conn.getresponse()
        assert r.status == 302, (r.status, r.read())
        loc = r.getheader("Location")
        conn.close()
        assert loc and loc.startswith("/community/dl/"), loc
        ticket = loc.rsplit("/", 1)[-1]

        # 下载入口 HEAD：客户端会先用 HEAD 判定 302，再决定是否起正式下载。
        # 主服务没有 do_HEAD 时这里会返回 501，客户端会直接进入失败态。
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=20)
        conn.request("HEAD", "/community/api/apps/%s/download" % app_id,
                     headers={"Authorization": "Bearer " + TOKEN})
        r = conn.getresponse()
        assert r.status == 302, (r.status, r.getheaders())
        head_loc = r.getheader("Location")
        conn.close()
        assert head_loc and head_loc.startswith("/community/dl/"), head_loc

        # gateway HEAD：只取元信息，不读 body。
        conn = http.client.HTTPConnection("127.0.0.1", GATEWAY_PORT, timeout=20)
        conn.request("HEAD", "/community/dl/" + ticket)
        r = conn.getresponse()
        assert r.status == 200, (r.status, r.getheaders())
        assert r.getheader("Content-Length") == "5242880", r.getheaders()
        assert r.getheader("Content-Type") == "application/vnd.android.package-archive", r.getheaders()
        conn.close()

        # gateway Range
        conn = http.client.HTTPConnection("127.0.0.1", GATEWAY_PORT, timeout=20)
        conn.request("GET", "/community/dl/" + ticket, headers={"Range": "bytes=0-15"})
        r = conn.getresponse()
        data = r.read()
        assert r.status == 206, (r.status, r.getheaders(), data[:100])
        assert r.getheader("Content-Range") == "bytes 0-15/5242880", r.getheaders()
        assert len(data) == 16, len(data)
        conn.close()

        # 全量
        conn = http.client.HTTPConnection("127.0.0.1", GATEWAY_PORT, timeout=20)
        conn.request("GET", "/community/dl/" + ticket)
        r = conn.getresponse(); data = r.read()
        assert r.status == 200 and len(data) == 5242880, (r.status, len(data))
        conn.close()

        # 非法 Range
        conn = http.client.HTTPConnection("127.0.0.1", GATEWAY_PORT, timeout=20)
        conn.request("GET", "/community/dl/" + ticket, headers={"Range": "bytes=9999999-"})
        r = conn.getresponse(); r.read()
        assert r.status == 416, r.status
        conn.close()

        # 静态后台：应用市场已并入社区后台
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=20)
        conn.request("GET", "/community/admin.html")
        r = conn.getresponse(); body = r.read()
        assert r.status == 200 and "应用市场" in body.decode("utf-8") and "appsDash" in body.decode("utf-8"), r.status
        conn.close()

        # ---------- iOS OTA 安装清单 ----------
        # APK 应用不能生成 iOS 清单
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=20)
        conn.request("GET", "/community/api/apps/%s/ios-manifest.plist" % app_id)
        r = conn.getresponse(); body = r.read()
        assert r.status == 409, (r.status, body[:200])
        conn.close()

        # 插入一个已上架的 IPA 应用，验证清单 XML、bundle id、下载直链与分享页
        ipa_id = uuid.uuid4().hex
        ipa_vid = uuid.uuid4().hex
        ipa_download = "http://127.0.0.1:%d/sample.ipa" % SOURCE_PORT
        cdb = sqlite3.connect(DB)
        cdb.execute(
            "INSERT INTO community_apps(id,submitter_id,name,icon,platform,package_type,package_name,"
            "category_id,subcategory_id,description,share_reason,status,featured,download_count,"
            "current_version_id,created,updated,published_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (ipa_id, "u_smoke", "iOS 冒烟应用", icon, "ios", "ipa", "com.liuying.ios.smoke",
             cat["id"], sub["id"], "用于验证 iOS OTA 安装清单与分享页。", "这个 iOS 版本值得一试。",
             2, 0, 0, ipa_vid, time.time(), time.time(), time.time()))
        cdb.execute(
            "INSERT INTO community_app_versions(id,app_id,version_name,os_version,download_url,provider,"
            "share_code,screenshots,status,created,approved_at,updated) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            (ipa_vid, ipa_id, "1.2.3", "iOS 15+", ipa_download, "auto", "", json.dumps(shots),
             2, time.time(), time.time(), time.time()))
        cdb.commit(); cdb.close()

        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=20)
        conn.request("GET", "/community/api/apps/%s/ios-manifest.plist" % ipa_id,
                     headers={"Host": "www.yosar.cloud", "X-Forwarded-Proto": "https"})
        r = conn.getresponse(); body = r.read().decode("utf-8")
        assert r.status == 200, (r.status, body[:300])
        assert "application/xml" in (r.getheader("Content-Type") or ""), r.getheaders()
        assert "software-package</string>" in body, body
        assert "<string>com.liuying.ios.smoke</string>" in body, body
        assert "<string>1.2.3</string>" in body, body
        assert "https://www.yosar.cloud/community/dl/" in body, body
        assert body.startswith("<?xml") and "<plist" in body, body[:80]
        conn.close()

        # HEAD 清单：只取头，不写 body
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=20)
        conn.request("HEAD", "/community/api/apps/%s/ios-manifest.plist" % ipa_id)
        r = conn.getresponse(); r.read()
        assert r.status == 200, r.status
        assert "application/xml" in (r.getheader("Content-Type") or ""), r.getheaders()
        conn.close()

        # 分享落地页：服务端渲染 OG + JSON 数据
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=20)
        conn.request("GET", "/community/app/%s" % ipa_id, headers={"Host": "www.yosar.cloud"})
        r = conn.getresponse(); body = r.read().decode("utf-8")
        assert r.status == 200, (r.status, body[:200])
        assert "<title>iOS 冒烟应用 v1.2.3 · 流萤社区应用分享</title>" in body, body[:400]
        assert 'property="og:image"' in body and "og:url" in body, body[:400]
        assert 'id="app-data"' in body and '"name":"iOS 冒烟应用"' in body, body[:600]
        assert "在 iPhone 上安装" in body, "iOS 安装文案缺失"
        conn.close()

        # 不存在的应用分享页：404 HTML
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=20)
        conn.request("GET", "/community/app/does-not-exist-000000")
        r = conn.getresponse(); body = r.read().decode("utf-8")
        assert r.status == 404 and "应用不存在" in body, (r.status, body[:200])
        conn.close()

        # 旧独立入口只做兼容跳转
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=20)
        conn.request("GET", "/community/admin-apps.html")
        r = conn.getresponse(); body = r.read()
        assert r.status == 200 and "/community/admin.html#apps" in body.decode("utf-8"), r.status
        conn.close()

        print("APP_MARKET_SMOKE_OK")
        print(json.dumps({"appId": app_id, "version": "1.1.0", "range": "bytes 0-15/5242880"}, ensure_ascii=False))
    finally:
        srv.shutdown()
        for p, f in procs:
            p.terminate()
            try:
                p.wait(timeout=3)
            except Exception:
                p.kill()
            f.close()


if __name__ == "__main__":
    main()
