# -*- coding: utf-8 -*-
"""应用市场输入校验、provider 识别与媒体路径校验。"""
import os
import re
import ipaddress
import urllib.parse

from common import resolve_token, check_sensitive

MAX_NAME = 40
MIN_NAME = 2
MAX_PACKAGE = 128
MAX_VERSION = 32
MAX_OS = 64
MAX_DESC = 3000
MIN_DESC = 20
MAX_SHARE = 500
MIN_SHARE = 10
MAX_URL = 2048
MAX_SCREENSHOTS = 9
MIN_SCREENSHOTS = 3
MAX_SHARE_CODE = 64

PLATFORM_OF_TYPE = {
    "apk": "android", "ipa": "ios", "store": "ios",
    "hap": "harmony", "app": "harmony",
    "exe": "windows", "msi": "windows",
}
PACKAGE_TYPES = tuple(PLATFORM_OF_TYPE.keys())
PLATFORMS = ("android", "ios", "harmony", "windows")

PROVIDER_HOSTS = [
    ("lanzou", ("lanzou", "lanzoux", "lanzouy", "lan Zou".lower())),
    ("pan123", ("123pan", "123684", "123865")),
    ("cow", ("cowtransfer",)),
    ("feijipan", ("feijipan",)),
    ("ec", ("yun.139", "139.com")),
    ("fc", ("fangcloud",)),
    ("pcx", ("chaoxing",)),
    ("pgd", ("drive.google", "docs.google")),
    ("pdp", ("dropbox",)),
    ("baidu", ("pan.baidu", "yun.baidu")),
    ("quark", ("pan.quark", "quark")),
    ("uc", ("drive.uc", "uc.cn")),
    ("aliyun", ("aliyundrive", "alipan", "aliyun")),
    ("xunlei", ("xunlei",)),
    ("115", ("115",)),
    ("guangya", ("guangya", "光鸭")),
    ("tianyi", ("cloud.189", "189.cn")),
]

LOGIN_REQUIRED = {"baidu", "quark", "uc", "aliyun", "xunlei", "115", "guangya", "tianyi"}
PUBLIC_PROVIDERS = {"official", "github", "lanzou", "pan123", "cow", "feijipan",
                    "ec", "fc", "pcx", "pgd", "pdp"}


def uid_of(c, handler):
    return resolve_token(c, handler.headers.get("Authorization", ""))


def body_of(handler):
    body = handler._json_body()
    return body if isinstance(body, dict) else {}


def get(body, *names, default=""):
    for n in names:
        if n in body and body[n] is not None:
            return body[n]
    return default


def s(v, limit=None):
    v = str(v or "").strip()
    return v[:limit] if limit else v


def detect_provider(url):
    host = (urllib.parse.urlparse(url or "").hostname or "").lower()
    if host in ("github.com", "www.github.com"):
        return "github"
    for provider, needles in PROVIDER_HOSTS:
        if any(n in host for n in needles):
            return provider
    return "official"


def validate_http_url(url):
    if not url or len(url) > MAX_URL:
        return "下载链接不能为空且不超过 2048 字符"
    try:
        p = urllib.parse.urlparse(url)
    except Exception:
        return "下载链接格式不正确"
    if p.scheme not in ("http", "https"):
        return "下载链接只支持 http/https"
    if not p.hostname:
        return "下载链接缺少域名"
    if p.username or p.password:
        return "下载链接不能包含账号密码"
    host = p.hostname.lower().strip("[]")
    if host in ("localhost", "localhost.localdomain"):
        return "下载链接不能指向本机"
    try:
        ip = ipaddress.ip_address(host)
        allow_private = os.environ.get("APP_ALLOW_PRIVATE", "0") == "1"
        if not allow_private and (ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved):
            return "下载链接不能指向内网地址"
    except ValueError:
        pass
    return ""


def validate_app_store_url(url):
    """iOS App Store 链接：只接受 apple 官方商店页面。"""
    if not url or len(url) > MAX_URL:
        return "App Store 链接不能为空且不超过 2048 字符"
    try:
        p = urllib.parse.urlparse(url)
    except Exception:
        return "App Store 链接格式不正确"
    if p.scheme != "https":
        return "App Store 链接必须使用 https"
    if p.username or p.password:
        return "App Store 链接不能包含账号密码"
    host = (p.hostname or "").lower().strip(".")
    if host not in ("apps.apple.com", "itunes.apple.com"):
        return "App Store 链接必须来自 apps.apple.com"
    path = p.path or ""
    if "/app/" not in path or not re.search(r"id\d{6,}", url):
        return "App Store 链接必须指向具体应用页面"
    return ""


def media_ok(path, uid):
    if not path or not isinstance(path, str):
        return False
    if ".." in path or "\\" in path:
        return False
    prefix = "/community/api/media/community_img_%s_" % (uid or "")[:8]
    if not path.startswith(prefix):
        return False
    name = path[len("/community/api/media/"):]
    return bool(re.match(r"^community_img_[A-Za-z0-9_]+_[A-Za-z0-9]+\.[A-Za-z0-9]+$", name))


def normalize_payload(c, uid, body, require_all=True):
    """把 API 的 camelCase 投稿字段校验并归一化为内部 snake_case。

    返回 (data, error)。error 为字符串。
    """
    name = s(get(body, "name", "appName"), MAX_NAME)
    icon = s(get(body, "icon", "appIcon"))
    package_type = s(get(body, "packageType", "package_type")).lower()
    platform = s(get(body, "platform")).lower()
    package_name = s(get(body, "packageName", "package_name"), MAX_PACKAGE)
    category_id = s(get(body, "categoryId", "category_id"))
    subcategory_id = s(get(body, "subcategoryId", "subcategory_id"))
    description = s(get(body, "description", "intro"))
    share_reason = s(get(body, "shareReason", "share_reason", "shareStory"))
    download_url = s(get(body, "downloadUrl", "download_url", "sourceUrl"))
    version_name = s(get(body, "versionName", "version", "version_name"), MAX_VERSION)
    os_version = s(get(body, "osVersion", "os_version"), MAX_OS)
    share_code = s(get(body, "shareCode", "share_code", "pwd"), MAX_SHARE_CODE)
    screenshots = get(body, "screenshots", default=[])

    if len(name) < MIN_NAME:
        return None, "应用名称至少 2 个字"
    if not icon or not media_ok(icon, uid):
        return None, "应用图标必须是当前账号上传的本站图片"
    if package_type not in PACKAGE_TYPES:
        return None, "packageType 只支持 apk/ipa/store/hap/app/exe/msi"
    if package_type == "store":
        if platform and platform not in ("ios", "windows"):
            return None, "store 类型只支持 iOS App Store 或 Windows 商店链接"
        platform = platform or "ios"
    else:
        derived = PLATFORM_OF_TYPE[package_type]
        if platform and platform not in PLATFORMS:
            return None, "platform 只支持 android/ios/harmony/windows"
        if platform and platform != derived:
            return None, "platform 与 packageType 不匹配"
        platform = derived
    if len(package_name) < 2 or not re.match(r"^[A-Za-z0-9._-]{2,128}$", package_name):
        return None, "包名/应用标识需为 2–128 位字母、数字、点、下划线或短横线"
    if not category_id or not subcategory_id:
        return None, "必须选择应用大类和子分类"
    if len(description) < MIN_DESC:
        return None, "应用介绍至少 20 个字"
    if len(share_reason) < MIN_SHARE:
        return None, "分享感言至少 10 个字"
    if not isinstance(screenshots, list) or not all(isinstance(x, str) for x in screenshots):
        return None, "screenshots 必须是图片地址数组"
    screenshots = [x.strip() for x in screenshots if x.strip()]
    if len(screenshots) < MIN_SCREENSHOTS or len(screenshots) > MAX_SCREENSHOTS:
        return None, "应用截图必须为 3–9 张"
    if len(set(screenshots)) != len(screenshots):
        return None, "应用截图不能重复"
    for path in screenshots:
        if not media_ok(path, uid):
            return None, "应用截图必须是当前账号上传的本站图片"
    if package_type == "store" and platform == "ios":
        url_err = validate_app_store_url(download_url)
    else:
        url_err = validate_http_url(download_url)
    if url_err:
        return None, url_err
    if not version_name:
        return None, "应用版本号不能为空"
    provider = "appstore" if (package_type == "store" and platform == "ios") else detect_provider(download_url)
    # 敏感词：level=0 直接拒绝；level=1 保留待审
    hits = check_sensitive(c, name + "\n" + description + "\n" + share_reason)
    blocked = [h["word"] for h in hits if h["level"] == 0]
    if blocked:
        return None, "内容包含敏感词：" + "、".join(blocked[:5])
    return {
        "name": name, "icon": icon, "platform": platform,
        "package_type": package_type, "package_name": package_name,
        "category_id": category_id, "subcategory_id": subcategory_id,
        "description": description, "share_reason": share_reason,
        "download_url": download_url, "provider": provider,
        "share_code": share_code, "screenshots": screenshots,
        "version_name": version_name, "os_version": os_version,
    }, ""
