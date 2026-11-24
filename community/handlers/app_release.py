# -*- coding: utf-8 -*-
"""客户端版本发布与检查更新。

公开接口：
    GET /community/api/app/version?platform=android&version=0.9.39&build=110
管理接口（沿用社区后台 token / ops 权限）：
    GET    /community/api/admin/app-releases
    POST   /community/api/admin/app-releases
    DELETE /community/api/admin/app-releases/<id>
    POST   /community/api/admin/upload-package

设计要点：
- Android / iOS 各自一条发布线，按 version+build 比较；只有 status=1 的版本对客户端可见。
- 后台保留全部历史发布记录，客户端永远只拿到当前平台最高且已上线的版本。
- 安装包可直接上传 APK/IPA（≤128MB，Nginx 侧 160MB），也可填写外链（Codemagic、对象存储等）。
"""
import hashlib
import io
import os
import re
import threading
import time
import uuid
import urllib.parse
import zipfile

from common import row_dict, rate_limit
from core.settings import settings
from handlers.admin_api import _authed

MAX_PACKAGE = 128 * 1024 * 1024  # 128MB；完整双端包已超过 100MB，不能再卡在旧 95MB
PLATFORMS = ("android", "ios")
STATUS_DRAFT = 0
STATUS_ONLINE = 1


def init_schema(c):
    c.execute(
        "CREATE TABLE IF NOT EXISTS community_app_releases("
        "id TEXT PRIMARY KEY,"
        "platform TEXT NOT NULL,"
        "version_name TEXT NOT NULL,"
        "build_number INTEGER NOT NULL DEFAULT 0,"
        "download_url TEXT NOT NULL DEFAULT '',"
        "package_size TEXT NOT NULL DEFAULT '',"
        "sha256 TEXT NOT NULL DEFAULT '',"
        "notes TEXT NOT NULL DEFAULT '',"
        "force_update INTEGER NOT NULL DEFAULT 0,"
        "status INTEGER NOT NULL DEFAULT 1,"
        "channel TEXT NOT NULL DEFAULT 'stable',"
        "rollout INTEGER NOT NULL DEFAULT 100,"
        "created REAL NOT NULL DEFAULT 0,"
        "updated REAL NOT NULL DEFAULT 0,"
        "published_at REAL NOT NULL DEFAULT 0)"
    )
    c.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_app_release_ver"
        " ON community_app_releases(platform, version_name, build_number)"
    )
    # 老库迁移：按渠道分发 + 灰度比例。CREATE TABLE IF NOT EXISTS 不会补列。
    cols = {r[1] for r in c.execute("PRAGMA table_info(community_app_releases)").fetchall()}
    if "channel" not in cols:
        c.execute("ALTER TABLE community_app_releases ADD COLUMN channel TEXT NOT NULL DEFAULT 'stable'")
    if "rollout" not in cols:
        c.execute("ALTER TABLE community_app_releases ADD COLUMN rollout INTEGER NOT NULL DEFAULT 100")
    if "sha256" not in cols:
        c.execute("ALTER TABLE community_app_releases ADD COLUMN sha256 TEXT NOT NULL DEFAULT ''")
    c.execute(
        "CREATE INDEX IF NOT EXISTS idx_app_release_platform"
        " ON community_app_releases(platform, status, build_number DESC, published_at DESC)"
    )


# ---------------- 公共 ----------------
def _clean(v, limit=4000):
    return str(v or "").strip()[:limit]


def _as_int(v, default=0):
    try:
        return int(str(v).strip())
    except Exception:
        return default


def _as_bool(v):
    if isinstance(v, bool):
        return v
    return str(v or "").strip().lower() in ("1", "true", "yes", "on")


def _ver_key(version):
    """把 0.9.40 / v0.10.1 / 2.0.0-beta 变成可比较的整数元组。"""
    s = str(version or "").strip().lower()
    if s.startswith("v"):
        s = s[1:]
    nums = re.findall(r"\d+", s.split("-", 1)[0])
    return tuple(int(x) for x in nums[:4]) if nums else (0,)


def _is_newer(latest_version, latest_build, current_version, current_build):
    """先比语义版本，版本相同再比 build。缺失当前版本时视为需要更新。"""
    lv = _ver_key(latest_version)
    cv = _ver_key(current_version)
    # 对齐长度，避免 0.9 被当成 0.9.0 后比较出错
    width = max(len(lv), len(cv), 3)
    lv = lv + (0,) * (width - len(lv))
    cv = cv + (0,) * (width - len(cv))
    if lv > cv:
        return True
    if lv < cv:
        return False
    lb = _as_int(latest_build, 0)
    cb = _as_int(current_build, 0)
    return lb > cb


def _locale_time(ts):
    try:
        if not ts or float(ts) <= 0:
            return ""
        return time.strftime("%Y-%m-%d %H:%M", time.localtime(float(ts)))
    except Exception:
        return ""


_SHA_CACHE = {}
_SHA_LOCK = threading.Lock()


def _package_sha256(download_url):
    """本地上传的安装包按文件内容算 SHA-256；按 (路径,大小,mtime) 缓存，避免每次请求重算。"""
    raw = str(download_url or "")
    prefix = "/community/api/media/"
    if not raw.startswith(prefix):
        return ""
    name = os.path.basename(urllib.parse.unquote(raw[len(prefix):]))
    if not name or "/" in name or "\\" in name:
        return ""
    path = os.path.join(settings.files_dir, name)
    try:
        st = os.stat(path)
        if not os.path.isfile(path):
            return ""
        key = (path, st.st_size, int(st.st_mtime))
        with _SHA_LOCK:
            hit = _SHA_CACHE.get(path)
        if hit and hit[0] == key:
            return hit[1]
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        digest = h.hexdigest()
        with _SHA_LOCK:
            _SHA_CACHE[path] = (key, digest)
        return digest
    except Exception:
        return ""


def _item(row):
    d = row_dict(row)
    if not d:
        return None
    return {
        "id": d.get("id", ""),
        "platform": d.get("platform", ""),
        "version": d.get("version_name", ""),
        "build": int(d.get("build_number") or 0),
        "downloadUrl": d.get("download_url", ""),
        "packageSize": d.get("package_size", ""),
        "sha256": _package_sha256(d.get("download_url", "")) or d.get("sha256", ""),
        "notes": d.get("notes", ""),
        "force": bool(d.get("force_update")),
        "status": int(d.get("status") or 0),
        "channel": (d.get("channel") or "stable"),
        "rollout": int(d.get("rollout") if d.get("rollout") is not None else 100),
        "publishedAt": float(d.get("published_at") or 0),
        "publishedAtText": _locale_time(d.get("published_at") or 0),
        "createdAt": float(d.get("created") or 0),
        "updatedAt": float(d.get("updated") or 0),
    }


def _release_bucket(device, platform, version, build):
    import hashlib
    h = hashlib.sha256(("%s|%s|%s|%s" % (device or "anonymous", platform, version, build)).encode("utf-8")).hexdigest()[:8]
    return int(h, 16) % 100


def _latest(c, platform, channel="stable", device="", honor_rollout=False):
    """按语义版本 + build 取最高版本；不能只按 build，否则 0.9.40 build 999
    会压过 0.10.0 build 1。发布记录量很小，取全量在内存里比较。

    channel: stable 只看 stable；beta 可看 stable+beta；internal 全部。
    honor_rollout: 按 device 稳定分桶，未命中灰度的用户回退到上一个全量版本。
    """
    rows = c.execute(
        "SELECT * FROM community_app_releases WHERE platform=? AND status=1",
        (platform,),
    ).fetchall()
    allowed = {"stable"} if channel == "stable" else ({"stable", "beta"} if channel == "beta" else {"stable", "beta", "internal"})
    items = [x for x in (_item(r) for r in rows) if x and x.get("channel", "stable") in allowed]
    if not items:
        return None
    items.sort(key=lambda x: (
        _ver_key(x["version"]), int(x["build"]), float(x["publishedAt"] or 0)
    ), reverse=True)
    for item in items:
        rollout = int(item.get("rollout") or 100)
        if honor_rollout and rollout < 100:
            if _release_bucket(device, platform, item["version"], item["build"]) >= max(0, rollout):
                continue
        return item
    return None


def _absolute_url(handler, url):
    url = _clean(url, 2000)
    if not url:
        return ""
    if url.startswith("//"):
        return "https:" + url
    if url.startswith("/"):
        return settings.public_origin + url
    return url


def _public_platform(handler):
    q = urllib.parse.parse_qs(urllib.parse.urlparse(handler.path).query)
    p = _clean((q.get("platform") or [""])[0], 20).lower()
    if p in PLATFORMS:
        return p
    ua = (handler.headers.get("User-Agent") or "").lower()
    if "iphone" in ua or "ipad" in ua or "ios" in ua:
        return "ios"
    return "android"


# ---------------- 公开检查更新 ----------------
def _handle_public_version(self, c, u, api, method):
    if api != "/app/version":
        return False
    if method != "GET":
        self._err(405, "method not allowed")
        return True
    platform = _public_platform(self)
    q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
    current_version = _clean((q.get("version") or [""])[0], 80)
    current_build = _as_int((q.get("build") or ["0"])[0], 0)
    channel = _clean((q.get("channel") or ["stable"])[0], 20).lower()
    if channel not in ("stable", "beta", "internal"):
        channel = "stable"
    device = _clean((q.get("device") or [""])[0], 96)
    if not device:
        device = "%s|%s" % (
            self.headers.get("CF-Connecting-IP", "") or self.client_address[0],
            self.headers.get("User-Agent", "")[:120],
        )
    latest = _latest(c, platform, channel=channel, device=device, honor_rollout=True)
    if not latest:
        self._ok({
            "platform": platform,
            "current": {"version": current_version, "build": current_build},
            "latest": None,
            "hasUpdate": False,
            "force": False,
            "channel": channel,
        })
        return True

    has_update = _is_newer(latest["version"], latest["build"], current_version, current_build)
    download_url = _absolute_url(self, latest["downloadUrl"])
    # 已上线但没有可用下载地址时，不向客户端弹一个点不动的更新。
    if latest["status"] == STATUS_ONLINE and not download_url:
        has_update = False

    self._ok({
        "platform": platform,
        "current": {"version": current_version, "build": current_build},
        "latest": {
            **latest,
            "downloadUrl": download_url,
        },
        "hasUpdate": has_update,
        "force": bool(has_update and latest["force"]),
        "downloadUrl": download_url,
        "notes": latest["notes"],
        "packageSize": latest["packageSize"],
        "publishedAt": latest["publishedAt"],
        "publishedAtText": latest["publishedAtText"],
        "channel": channel,
    })
    return True


# ---------------- 管理端 ----------------
def _admin_list(self, c):
    rows = c.execute(
        "SELECT * FROM community_app_releases ORDER BY platform ASC, build_number DESC, published_at DESC, created DESC"
    ).fetchall()
    items = [x for x in (_item(r) for r in rows) if x]
    # SQLite 无法按语义版本排序；后台列表按平台 + 版本 + build 倒序，
    # 避免 build 号大的旧版本压在新版本上面。
    items.sort(key=lambda x: (_ver_key(x["version"]), int(x["build"])), reverse=True)
    items.sort(key=lambda x: 0 if x["platform"] == "android" else 1)
    latest = {}
    for p in PLATFORMS:
        latest[p] = _latest(c, p, channel="stable")
        latest[p + ":beta"] = _latest(c, p, channel="beta")
    self._ok({"items": items, "latest": latest, "platforms": list(PLATFORMS)})


def _admin_save(self, c):
    body = self._json_body() or {}
    # 兼容前端直接提交字段，也兼容 {item:{...}} 包一层。
    if isinstance(body.get("item"), dict):
        body = body["item"]
    rid = _clean(body.get("id"), 80)
    platform = _clean(body.get("platform"), 20).lower()
    if platform not in PLATFORMS:
        self._err(400, "平台仅支持 android / ios")
        return
    version = _clean(body.get("version") or body.get("versionName"), 80)
    if not version:
        self._err(400, "请填写版本号")
        return
    if not re.match(r"^[0-9]+(\.[0-9]+)+(?:[-+][0-9A-Za-z.\-]+)?$", version):
        self._err(400, "版本号格式不正确（示例 0.9.40 / 1.0.0-beta）")
        return
    build = _as_int(body.get("build") or body.get("buildNumber"), 0)
    if build < 0:
        self._err(400, "build 号不能为负数")
        return
    download_url = _clean(body.get("downloadUrl") or body.get("download_url"), 2000)
    if download_url and not (download_url.startswith("http://") or download_url.startswith("https://") or download_url.startswith("/")):
        self._err(400, "下载地址需为 http(s) 链接或站内路径")
        return
    package_size = _clean(body.get("packageSize") or body.get("package_size"), 80)
    sha256 = _clean(body.get("sha256") or body.get("sha256sum"), 64).lower()
    if sha256 and not re.fullmatch(r"[0-9a-f]{64}", sha256):
        self._err(400, "SHA-256 必须是 64 位十六进制")
        return
    notes = _clean(body.get("notes"), 4000)
    force = 1 if _as_bool(body.get("force") if "force" in body else body.get("force_update")) else 0
    status = 1 if _as_int(body.get("status"), 1) == 1 else 0
    channel = _clean(body.get("channel") or "stable", 20).lower()
    if channel not in ("stable", "beta", "internal"):
        self._err(400, "渠道仅支持 stable / beta / internal")
        return
    try:
        rollout = int(body.get("rollout") if body.get("rollout") is not None else 100)
    except Exception:
        self._err(400, "灰度比例必须是整数")
        return
    if rollout < 0 or rollout > 100:
        self._err(400, "灰度比例需在 0-100 之间")
        return
    if status == 1 and not download_url:
        self._err(400, "上线前请先填写或上传安装包地址")
        return

    now = time.time()
    existing = None
    if rid:
        existing = c.execute("SELECT * FROM community_app_releases WHERE id=?", (rid,)).fetchone()
        if not existing:
            self._err(404, "发布记录不存在")
            return

    # 同平台同版本同 build 不允许重复，避免后台列表和客户端比较产生歧义。
    dup = c.execute(
        "SELECT id FROM community_app_releases"
        " WHERE platform=? AND version_name=? AND build_number=? AND id<>?",
        (platform, version, build, rid or ""),
    ).fetchone()
    if dup:
        self._err(409, "该平台已存在相同版本号和 build 号的发布记录")
        return

    if existing:
        old = row_dict(existing)
        published_at = float(old.get("published_at") or 0)
        if status == 1 and not published_at:
            published_at = now
        c.execute(
            "UPDATE community_app_releases SET platform=?, version_name=?, build_number=?,"
            " download_url=?, package_size=?, sha256=?, notes=?, force_update=?, status=?,"
            " channel=?, rollout=?, updated=?, published_at=? WHERE id=?",
            (platform, version, build, download_url, package_size, sha256, notes, force,
             status, channel, rollout, now, published_at, rid),
        )
    else:
        rid = rid or ("rel_" + uuid.uuid4().hex[:14])
        published_at = now if status == 1 else 0
        c.execute(
            "INSERT INTO community_app_releases"
            "(id,platform,version_name,build_number,download_url,package_size,sha256,notes,"
            " force_update,status,channel,rollout,created,updated,published_at)"
            " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (rid, platform, version, build, download_url, package_size, sha256, notes, force,
             status, channel, rollout, now, now, published_at),
        )
    c.commit()
    row = c.execute("SELECT * FROM community_app_releases WHERE id=?", (rid,)).fetchone()
    self._ok({"item": _item(row), "latest": _latest(c, platform)})


def _admin_delete(self, c, rid):
    row = c.execute("SELECT id FROM community_app_releases WHERE id=?", (rid,)).fetchone()
    if not row:
        self._err(404, "发布记录不存在")
        return
    c.execute("DELETE FROM community_app_releases WHERE id=?", (rid,))
    c.commit()
    self._ok({"deleted": rid})


def _admin_upload_package(self, c):
    if not rate_limit(self, "admin_upload_package"):
        self._err(429, "上传过于频繁，请稍后再试")
        return
    fields, files = self._multipart(MAX_PACKAGE + 8192)
    if files is None:
        self._err(400, "上传数据无效")
        return
    data = None
    filename = ""
    for _, (fn, payload) in files.items():
        if payload:
            data, filename = payload, fn
            break
    if not data:
        self._err(400, "缺少安装包文件")
        return
    ext = os.path.splitext(filename)[1].lower()
    if ext not in (".apk", ".ipa"):
        self._err(400, "仅支持 APK 或 IPA 安装包")
        return
    if len(data) > MAX_PACKAGE:
        self._err(413, "安装包过大（≤128MB）")
        return
    # APK 和 IPA 本质都是 zip；再检查关键条目，防止把普通压缩包当安装包。
    try:
        if not zipfile.is_zipfile(io.BytesIO(data)):
            raise ValueError("not zip")
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            names = z.namelist()
            if ext == ".apk":
                if "AndroidManifest.xml" not in names:
                    raise ValueError("missing AndroidManifest.xml")
            else:
                if not any(n.startswith("Payload/") and n.endswith(".app/Info.plist") for n in names):
                    raise ValueError("missing Payload/*.app/Info.plist")
    except Exception:
        self._err(400, "安装包格式校验失败（APK/IPA 文件无效）")
        return
    out = "community_pkg_%s%s" % (uuid.uuid4().hex[:18], ext)
    path = os.path.join(settings.files_dir, out)
    with open(path, "wb") as f:
        f.write(data)
    c.commit()
    size_text = ("%.1f MB" % (len(data) / 1024.0 / 1024.0)) if len(data) >= 1024 * 1024 else ("%.0f KB" % (len(data) / 1024.0))
    self._ok({
        "url": "/community/api/media/" + out,
        "name": out,
        "size": len(data),
        "sizeText": size_text,
        "sha256": hashlib.sha256(data).hexdigest(),
        "ext": ext,
    })


def _handle_admin(self, c, api, method):
    if api == "/admin/app-releases":
        if method == "GET":
            _admin_list(self, c)
            return True
        if method == "POST":
            _admin_save(self, c)
            return True
        self._err(405, "method not allowed")
        return True
    m = re.match(r"^/admin/app-releases/([\w\-]+)$", api)
    if m:
        if method == "DELETE":
            _admin_delete(self, c, m.group(1))
            return True
        self._err(405, "method not allowed")
        return True
    if api == "/admin/upload-package":
        if method != "POST":
            self._err(405, "method not allowed")
            return True
        _admin_upload_package(self, c)
        return True
    return False


def dispatch(self, c, u, api, method):
    if api == "/app/version":
        return _handle_public_version(self, c, u, api, method)
    if api.startswith("/admin/app-releases") or api == "/admin/upload-package":
        if _authed(c, self) is None:
            return True
        return _handle_admin(self, c, api, method)
    return False
