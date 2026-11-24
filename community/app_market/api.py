# -*- coding: utf-8 -*-
"""应用市场主服务 API 分发：只做鉴权/限流/参数路由，业务在 service.py。"""
import re
import json
import hmac
import urllib.parse
from xml.sax.saxutils import escape as xml_escape

from common import rate_limit, resolve_token
from core.settings import settings
from core.security import cors_headers, security_headers
from app_market import service
from app_market.ticket import issue, internal_token
from app_market.behavior import record_app_behavior
from app_market.util import uid_of, body_of

ID_RE = re.compile(r"^[A-Za-z0-9_-]{16,64}$")


def _login(self, c):
    uid = uid_of(c, self)
    if not uid:
        self._err(401, "请先登录")
    return uid


def _query(u):
    return {k: (v[0] if v else "") for k, v in urllib.parse.parse_qs(u.query).items()}


def _redirect(self, location):
    self.send_response(302)
    self.send_header("Location", location)
    self.send_header("Content-Length", "0")
    self.send_header("Cache-Control", "no-store")
    for k, v in cors_headers(self.headers.get("Origin", ""), settings.cors_origins).items():
        self.send_header(k, v)
    for k, v in security_headers(is_html=False, secure=True).items():
        self.send_header(k, v)
    self.end_headers()


def _download(self, c, u, app_id, method):
    row = c.execute("SELECT * FROM community_apps WHERE id=?", (app_id,)).fetchone()
    if not row or row["status"] != 2:
        self._err(404, "应用不存在或未上架")
        return
    v = c.execute("SELECT * FROM community_app_versions WHERE id=? AND app_id=? AND status=2",
                  (row["current_version_id"], app_id)).fetchone()
    if not v:
        self._err(404, "应用没有可用版本")
        return
    if (row["package_type"] or "").lower() == "store":
        target = (v["download_url"] or "").strip()
        if not (target.startswith("https://") or target.startswith("http://")):
            self._err(409, "该应用未配置有效的商店链接")
            return
        if method == "GET":
            c.execute("UPDATE community_apps SET download_count=download_count+1 WHERE id=?", (app_id,))
            uid = resolve_token(c, self.headers.get("Authorization", ""))
            record_app_behavior(c, uid, app_id, "download")
            c.commit()
        _redirect(self, target)
        return
    ticket = issue(v["id"], app_id)
    if method == "GET":
        c.execute("UPDATE community_apps SET download_count=download_count+1 WHERE id=?", (app_id,))
        uid = resolve_token(c, self.headers.get("Authorization", ""))
        record_app_behavior(c, uid, app_id, "download")
        c.commit()
    _redirect(self, "/community/dl/" + ticket)


def _ios_manifest(self, c, u, app_id, method):
    """iOS OTA 安装清单（itms-services 协议）。

    设计约束：
    - 只对已上架、当前版本为 IPA 的应用签发；Android 包/未上架一律拒绝。
    - 清单里的 software-package 指向 `/community/dl/<ticket>`，由下载网关直接
      吐字节（不是 302 到网盘），Apple 安装器只认这个直链。
    - Bundle ID 来自投稿时填写的 package_name；填错时 iOS 会以“无法安装”结束，
      这是安装包元数据问题，服务端不做猜测。
    - 清单必须公网 HTTPS 可匿名访问，安装器不会带 Cookie / Authorization。
    """
    if method not in ("GET", "HEAD"):
        self._err(405, "method not allowed")
        return
    row = c.execute("SELECT * FROM community_apps WHERE id=? AND status=2", (app_id,)).fetchone()
    if not row:
        self._err(404, "应用不存在或未上架")
        return
    if (row["package_type"] or "").lower() != "ipa":
        self._err(409, "该应用不是 iOS 安装包")
        return
    v = c.execute("SELECT * FROM community_app_versions WHERE id=? AND app_id=? AND status=2",
                  (row["current_version_id"], app_id)).fetchone()
    if not v:
        self._err(404, "应用没有可用版本")
        return
    bundle_id = (row["package_name"] or "").strip()
    if not bundle_id:
        self._err(409, "该应用未填写 Bundle ID，无法生成 iOS 安装清单")
        return
    version_name = (v["version_name"] or "").strip()
    if not version_name:
        self._err(409, "该应用版本号为空，无法生成 iOS 安装清单")
        return
    # 安装清单可能被用户留在系统安装器里几分钟，ticket 给 6 小时，避免中途失效。
    ticket = issue(v["id"], app_id, ttl=21600)
    base = settings.public_origin
    package_url = base + "/community/dl/" + ticket
    icon_url = ""
    icon = (row["icon"] or "").strip()
    if icon.startswith("http://") or icon.startswith("https://"):
        icon_url = icon
    elif icon:
        icon_url = base + (icon if icon.startswith("/")
                           else "/community/api/media/" + urllib.parse.quote(icon))
    name = (row["name"] or "应用").strip()
    assets = (
        '<dict><key>kind</key><string>software-package</string>'
        '<key>url</key><string>%s</string></dict>' % xml_escape(package_url)
    )
    if icon_url:
        assets += (
            '<dict><key>kind</key><string>display-image</string>'
            '<key>needs-shine</key><false/>'
            '<key>url</key><string>%s</string></dict>' % xml_escape(icon_url)
        )
    plist = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0">\n<dict>\n<key>items</key>\n<array>\n<dict>\n'
        '<key>assets</key>\n<array>%s</array>\n'
        '<key>metadata</key>\n<dict>\n'
        '<key>bundle-identifier</key><string>%s</string>\n'
        '<key>bundle-version</key><string>%s</string>\n'
        '<key>kind</key><string>software</string>\n'
        '<key>title</key><string>%s</string>\n'
        '</dict>\n</dict>\n</array>\n</dict>\n</plist>\n'
    ) % (assets, xml_escape(bundle_id), xml_escape(version_name), xml_escape(name))
    if method == "GET":
        c.execute("UPDATE community_apps SET download_count=download_count+1 WHERE id=?", (app_id,))
        c.commit()
    self._send(200, plist.encode("utf-8"), "application/xml; charset=utf-8")


def _manifest(self, c, u, method):
    if method != "GET":
        self._err(405, "method not allowed")
        return
    tok = self.headers.get("X-Internal-Token", "")
    expected = internal_token()
    if not expected or not hmac.compare_digest(tok, expected):
        self._err(403, "internal token invalid")
        return
    q = _query(u)
    vid = q.get("versionId") or ""
    aid = q.get("appId") or ""
    if not vid or not aid:
        self._err(400, "missing versionId/appId")
        return
    app = c.execute("SELECT * FROM community_apps WHERE id=? AND status=2", (aid,)).fetchone()
    if not app:
        self._err(404, "app unavailable")
        return
    v = c.execute("SELECT * FROM community_app_versions WHERE id=? AND app_id=? AND status=2",
                  (vid, aid)).fetchone()
    if not v:
        self._err(404, "version unavailable")
        return
    self._ok({"manifest": {
        "appId": aid, "versionId": vid, "appName": app["name"],
        "versionName": v["version_name"], "packageType": app["package_type"],
        "downloadUrl": v["download_url"], "provider": v["provider"] or "auto",
        "shareCode": v["share_code"] or "", "fileName": v["file_name"] or "",
        "fileSize": v["file_size"] or 0, "contentType": v["content_type"] or "",
        "supportsRange": bool(v["supports_range"]),
    }})


def dispatch(self, c, u, api, method):
    if api == "/internal/app-download/manifest":
        _manifest(self, c, u, method)
        return True
    if not api.startswith("/apps"):
        return False

    # 分类 / 列表 / 我的
    if api == "/apps/categories" and method == "GET":
        self._ok({"list": service.category_tree(c)})
        return True
    if api == "/apps" and method == "GET":
        viewer = resolve_token(c, self.headers.get("Authorization", ""))
        self._ok(service.list_apps(c, u.query, viewer))
        return True
    if api == "/apps" and method == "POST":
        uid = _login(self, c)
        if not uid:
            return True
        if not rate_limit(self, "app_submit"):
            self._err(429, "投稿过于频繁，请稍后再试")
            return True
        body = body_of(self)
        data, err = service.create_app(c, uid, body)
        if err:
            self._err(400, err)
            return True
        self._ok(data)
        return True

    m = re.match(r"^/apps/by-user/([\w\-]+)$", api)
    if m and method == "GET":
        uid = m.group(1)
        q = _query(u)
        viewer = resolve_token(c, self.headers.get("Authorization", ""))
        try:
            page = int(q.get("page") or 1)
            size = int(q.get("pageSize") or 12)
        except ValueError:
            self._err(400, "分页参数不合法")
            return True
        self._ok(service.list_user_apps(c, uid, viewer, page, size))
        return True

    if api == "/apps/mine" and method == "GET":
        uid = _login(self, c)
        if not uid:
            return True
        self._ok(service.list_mine(c, uid))
        return True
    if api == "/apps/mine/favorites" and method == "GET":
        uid = _login(self, c)
        if not uid:
            return True
        self._ok(service.list_favorites(c, uid))
        return True

    m = re.match(r"^/apps/([A-Za-z0-9_-]+)(?:/(.+))?$", api)
    if not m:
        return False
    app_id = m.group(1)
    rest = m.group(2) or ""
    if not ID_RE.match(app_id):
        self._err(404, "应用不存在")
        return True

    # 应用主体
    if not rest:
        if method == "GET":
            viewer = resolve_token(c, self.headers.get("Authorization", ""))
            item, err = service.get_detail(c, app_id, viewer)
            if err:
                self._err(404, err)
                return True
            self._ok({"app": item})
            return True
        if method == "PUT":
            uid = _login(self, c)
            if not uid:
                return True
            data, err = service.update_app(c, uid, app_id, body_of(self))
            if err:
                self._err(400, err)
                return True
            self._ok(data)
            return True
        return False

    if rest == "submit" and method == "POST":
        uid = _login(self, c)
        if not uid:
            return True
        data, err = service.submit_app(c, uid, app_id, body_of(self))
        if err:
            self._err(400, err)
            return True
        self._ok(data)
        return True

    if rest == "download" and method in ("GET", "HEAD"):
        _download(self, c, u, app_id, method)
        return True

    if rest == "ios-manifest.plist" and method in ("GET", "HEAD"):
        _ios_manifest(self, c, u, app_id, method)
        return True

    if rest == "comments":
        if method == "GET":
            data, err = service.list_comments(c, app_id, u.query)
            if err:
                self._err(404, err)
                return True
            self._ok(data)
            return True
        if method == "POST":
            uid = _login(self, c)
            if not uid:
                return True
            if not rate_limit(self, "app_comment"):
                self._err(429, "评论过于频繁，请稍后再试")
                return True
            data, err = service.add_comment(c, uid, app_id, body_of(self))
            if err:
                self._err(400, err)
                return True
            self._ok(data)
            return True
        return False

    m = re.match(r"^comments/([A-Za-z0-9_-]+)$", rest)
    if m and method == "DELETE":
        uid = _login(self, c)
        if not uid:
            return True
        data, err = service.delete_comment(c, uid, app_id, m.group(1))
        if err:
            self._err(400, err)
            return True
        self._ok(data)
        return True

    if rest == "rating":
        if method == "GET":
            app = c.execute("SELECT rating_sum,rating_count FROM community_apps WHERE id=? AND status=2",
                            (app_id,)).fetchone()
            if not app:
                self._err(404, "应用不存在或未上架")
                return True
            uid = resolve_token(c, self.headers.get("Authorization", ""))
            my = 0
            if uid:
                r = c.execute("SELECT score FROM community_app_ratings WHERE user_id=? AND app_id=?",
                              (uid, app_id)).fetchone()
                my = r[0] if r else 0
            avg = round((app[0] or 0) / (app[1] or 1), 2) if app[1] else 0
            self._ok({"rating": avg, "ratingCount": app[1] or 0, "myRating": my})
            return True
        if method == "POST":
            uid = _login(self, c)
            if not uid:
                return True
            if not rate_limit(self, "app_rating"):
                self._err(429, "评分过于频繁")
                return True
            data, err = service.set_rating(c, uid, app_id, body_of(self))
            if err:
                self._err(400, err)
                return True
            self._ok(data)
            return True
        return False

    if rest == "favorite":
        if method not in ("POST", "DELETE"):
            return False
        uid = _login(self, c)
        if not uid:
            return True
        data, err = service.toggle_favorite(c, uid, app_id, add=(method == "POST"))
        if err:
            self._err(400, err)
            return True
        self._ok(data)
        return True

    if rest == "report" and method == "POST":
        uid = _login(self, c)
        if not uid:
            return True
        if not rate_limit(self, "app_report"):
            self._err(429, "举报过于频繁")
            return True
        data, err = service.add_report(c, uid, app_id, body_of(self))
        if err:
            self._err(400, err)
            return True
        self._ok(data)
        return True

    # 版本
    if rest == "versions" and method == "POST":
        uid = _login(self, c)
        if not uid:
            return True
        data, err = service.create_version(c, uid, app_id, body_of(self))
        if err:
            self._err(400, err)
            return True
        self._ok(data)
        return True

    m = re.match(r"^versions/([A-Za-z0-9_-]+)(/submit)?$", rest)
    if m:
        vid, is_submit = m.group(1), bool(m.group(2))
        uid = _login(self, c)
        if not uid:
            return True
        if is_submit and method == "POST":
            data, err = service.submit_version(c, uid, app_id, vid, body_of(self))
        elif method == "PUT":
            data, err = service.update_version(c, uid, app_id, vid, body_of(self))
        else:
            return False
        if err:
            self._err(400, err)
            return True
        self._ok(data)
        return True

    return False
