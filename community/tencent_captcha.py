# -*- coding: utf-8 -*-
"""腾讯云验证码（滑动拼图）服务端票据校验。

前端拿到 ticket / randstr 后，必须由服务端二次校验，否则前端结果可以被伪造。

支持两种接入版本：
- 验证码 2.0（2024-11 之后新建的默认版本）：前端 `TJCaptcha.js` + 服务端
  `DescribeCaptchaResult`（腾讯云 API TC3 签名）；
- 验证码 1.0（旧版）：前端 `TCaptcha.js` + 服务端 `ticket/verify`。

凭据全部只走环境变量：
- `COMMUNITY_TENCENT_CAPTCHA_APPID` / `..._SECRET`：控制台验证管理里的
  CaptchaAppId / AppSecretKey，必填；
- `COMMUNITY_TENCENT_SECRET_ID` / `..._SECRET_KEY`：腾讯云 API 密钥，2.0 票据
  校验需要；未配置时回退旧版 ticket/verify（1.0 可用，2.0 可能不兼容）；
- `COMMUNITY_TENCENT_CAPTCHA_MODE`：`2`（默认）或 `1`。

安全约束：密钥不下发客户端；票据一次性消费（哈希落库 UNIQUE）防重放；
校验失败一律 fail-closed；网络地址固定，不接受用户可控 URL。
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import sqlite3
import time
import urllib.parse
import urllib.request

API_HOST = "captcha.tencentcloudapi.com"
API_ACTION = "DescribeCaptchaResult"
API_VERSION = "2019-07-22"
LEGACY_VERIFY_URL = "https://ssl.captcha.qq.com/ticket/verify"
JS_URL_2 = "https://turing.captcha.qcloud.com/TJCaptcha.js"
JS_URL_1 = "https://turing.captcha.qcloud.com/TCaptcha.js"
TICKET_MAX = 4096
RANDSTR_MAX = 256
HTTP_TIMEOUT = 6

ERR_MESSAGES = {
    1: "人机验证失败，请重试",
    7: "人机验证票据与随机串不匹配，请重试",
    8: "人机验证票据已过期，请重试",
    9: "人机验证票据已使用，请重试",
    10: "人机验证票据与账号不匹配，请重试",
    15: "人机验证票据校验失败，请重试",
    16: "人机验证 AppId 与票据不匹配，请检查配置",
    21: "人机验证触发风控，请重试",
    25: "人机验证环境异常，请重试",
    26: "人机验证服务内部错误，请稍后再试",
    100: "人机验证密钥与票据不匹配，请检查配置",
    10001: "人机验证套餐未开通或已过期，请联系管理员",
}


def appid() -> str:
    return (os.environ.get("COMMUNITY_TENCENT_CAPTCHA_APPID") or "").strip()


def app_secret() -> str:
    return (os.environ.get("COMMUNITY_TENCENT_CAPTCHA_SECRET") or "").strip()


def api_secret_id() -> str:
    return (os.environ.get("COMMUNITY_TENCENT_SECRET_ID") or "").strip()


def api_secret_key() -> str:
    return (os.environ.get("COMMUNITY_TENCENT_SECRET_KEY") or "").strip()


def mode() -> str:
    raw = (os.environ.get("COMMUNITY_TENCENT_CAPTCHA_MODE") or "2").strip()
    return "1" if raw == "1" else "2"


def enabled() -> bool:
    """配置完整才启用，避免半配置导致全站发码不可用。

    2.0 票据校验必须走 DescribeCaptchaResult，因此除 CaptchaAppId/AppSecretKey
    外还需要腾讯云 API SecretId/SecretKey；缺任一即回退图片验证码。
    1.0 只需 CaptchaAppId/AppSecretKey。
    """
    aid = appid()
    secret = app_secret()
    if not (aid.isdigit() and len(secret) >= 8):
        return False
    if mode() == "2":
        return bool(api_secret_id() and api_secret_key())
    return True


def status() -> dict:
    if enabled():
        return {"provider": "tencent", "app_id": appid(), "mode": mode()}
    return {"provider": "cap", "app_id": "", "mode": mode()}


def _ensure(c) -> None:
    c.execute("""CREATE TABLE IF NOT EXISTS community_captcha_tickets(
        ticket_hash TEXT PRIMARY KEY,
        created REAL NOT NULL
    )""")
    c.execute("CREATE INDEX IF NOT EXISTS idx_captcha_ticket_created "
              "ON community_captcha_tickets(created)")


def _consume(c, ticket: str) -> bool:
    """票据一次性消费。返回 False 表示该票据已经用过（重放）。"""
    _ensure(c)
    now = time.time()
    c.execute("DELETE FROM community_captcha_tickets WHERE created<?",
              (now - 1800,))
    digest = hashlib.sha256(ticket.encode("utf-8")).hexdigest()
    try:
        c.execute("INSERT INTO community_captcha_tickets(ticket_hash,created) "
                  "VALUES(?,?)", (digest, now))
        c.commit()
        return True
    except sqlite3.IntegrityError:
        try:
            c.rollback()
        except Exception:
            pass
        return False


def _hmac(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def _verify_cloud(ticket: str, randstr: str, user_ip: str) -> tuple[bool, str]:
    """验证码 2.0：腾讯云 DescribeCaptchaResult（TC3-HMAC-SHA256）。"""
    secret_id = api_secret_id()
    secret_key = api_secret_key()
    if not secret_id or not secret_key:
        return False, "人机验证服务端密钥未配置，请联系管理员"

    payload = json.dumps({
        "CaptchaType": 9,
        "Ticket": ticket,
        "UserIp": (user_ip or "127.0.0.1")[:64],
        "Randstr": randstr,
        "CaptchaAppId": int(appid()),
        "AppSecretKey": app_secret(),
        "NeedGetCaptchaTime": 1,
    }, ensure_ascii=False, separators=(",", ":")).encode("utf-8")

    timestamp = int(time.time())
    date = time.strftime("%Y-%m-%d", time.gmtime(timestamp))
    content_type = "application/json; charset=utf-8"
    action = API_ACTION.lower()
    canonical_headers = (
        "content-type:%s\nhost:%s\nx-tc-action:%s\n"
        % (content_type, API_HOST, action)
    )
    signed_headers = "content-type;host;x-tc-action"
    canonical_request = (
        "POST\n/\n\n" + canonical_headers + "\n" + signed_headers + "\n"
        + hashlib.sha256(payload).hexdigest()
    )
    credential_scope = "%s/captcha/tc3_request" % date
    string_to_sign = (
        "TC3-HMAC-SHA256\n%d\n%s\n%s"
        % (timestamp, credential_scope,
           hashlib.sha256(canonical_request.encode("utf-8")).hexdigest())
    )
    secret_date = _hmac(("TC3" + secret_key).encode("utf-8"), date)
    secret_service = _hmac(secret_date, "captcha")
    secret_signing = _hmac(secret_service, "tc3_request")
    signature = hmac.new(secret_signing, string_to_sign.encode("utf-8"),
                         hashlib.sha256).hexdigest()
    authorization = (
        "TC3-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s"
        % (secret_id, credential_scope, signed_headers, signature)
    )

    req = urllib.request.Request(
        "https://%s/" % API_HOST,
        data=payload,
        headers={
            "Authorization": authorization,
            "Content-Type": content_type,
            "Host": API_HOST,
            "X-TC-Action": API_ACTION,
            "X-TC-Timestamp": str(timestamp),
            "X-TC-Version": API_VERSION,
            "Accept": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            raw = resp.read(65536)
        data = json.loads(raw.decode("utf-8", "replace"))
    except Exception:
        return False, "人机验证服务连接失败，请稍后再试"

    body = data.get("Response") if isinstance(data, dict) else None
    if not isinstance(body, dict):
        return False, "人机验证服务响应异常，请稍后再试"
    try:
        code = int(body.get("CaptchaCode") or 0)
    except Exception:
        code = 0
    if code != 1:
        return False, ERR_MESSAGES.get(code, "人机验证失败，请重试")
    return True, ""


def _verify_legacy(ticket: str, randstr: str, user_ip: str) -> tuple[bool, str]:
    """验证码 1.0：旧版 ticket/verify。"""
    payload = urllib.parse.urlencode({
        "aid": appid(),
        "AppSecretKey": app_secret(),
        "Ticket": ticket,
        "Randstr": randstr,
        "UserIP": (user_ip or "127.0.0.1")[:64],
    }).encode("utf-8")
    req = urllib.request.Request(
        LEGACY_VERIFY_URL,
        data=payload,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
            "User-Agent": "liuying-community/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            raw = resp.read(65536)
        data = json.loads(raw.decode("utf-8", "replace"))
    except Exception:
        return False, "人机验证服务连接失败，请稍后再试"

    try:
        response = int(data.get("response"))
    except Exception:
        response = 0
    if response != 1:
        try:
            err_code = int(data.get("err_code") or 0)
        except Exception:
            err_code = 0
        return False, ERR_MESSAGES.get(err_code, "人机验证失败，请重试")
    return True, ""


def verify(c, ticket: str, randstr: str, user_ip: str = "") -> tuple[bool, str]:
    """校验腾讯票据，返回 (ok, error_message)。"""
    if not enabled():
        return False, "人机验证暂未配置，请联系管理员"
    ticket = str(ticket or "").strip()
    randstr = str(randstr or "").strip()
    if not ticket or not randstr:
        return False, "请完成滑块验证"
    if len(ticket) > TICKET_MAX or len(randstr) > RANDSTR_MAX:
        return False, "人机验证参数异常"

    if mode() == "1":
        ok, msg = _verify_legacy(ticket, randstr, user_ip)
    elif api_secret_id() and api_secret_key():
        ok, msg = _verify_cloud(ticket, randstr, user_ip)
    else:
        # 2.0 未配云 API 密钥时先走旧接口；若控制台强制 2.0，需补
        # COMMUNITY_TENCENT_SECRET_ID / SECRET_KEY。
        ok, msg = _verify_legacy(ticket, randstr, user_ip)
    if not ok:
        return False, msg
    if not _consume(c, ticket):
        return False, "人机验证票据已使用，请重试"
    return True, ""


def page_html() -> str:
    """供 App WebView 加载的腾讯验证码页；域名与 H5 同源，便于域名校验。"""
    aid = appid()
    if not enabled():
        return ("<!doctype html><html><head><meta charset='utf-8'>"
                "<meta name='viewport' content='width=device-width,initial-scale=1'>"
                "<style>body{margin:0;background:#0b0b0c;color:#fff;font:14px/1.6 sans-serif;"
                "display:flex;align-items:center;justify-content:center;height:100vh}</style>"
                "</head><body>人机验证暂未配置</body></html>")
    aid_js = json.dumps(aid)
    is_v2 = mode() == "2"
    script_url = JS_URL_2 if is_v2 else JS_URL_1
    if is_v2:
        init_js = ("var host=document.getElementById('tcaptcha');"
                   "var cap=new TencentCaptcha(host,%s,function(res){bridge(res||"
                   "{ret:-1,errorMessage:'empty result'});},{type:'popup'});"
                   "cap.show();" % aid_js)
    else:
        init_js = ("var cap=new TencentCaptcha(%s,function(res){bridge(res||"
                   "{ret:-1,errorMessage:'empty result'});},{type:'popup'});"
                   "cap.show();" % aid_js)
    return f"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<title>人机验证</title>
<style>
html,body{{margin:0;padding:0;width:100%;height:100%;background:#0b0b0c;overflow:hidden}}
#tcaptcha{{position:fixed;inset:0}}
#fallback{{position:fixed;inset:0;display:none;align-items:center;justify-content:center;color:#fff;font:14px/1.6 -apple-system,BlinkMacSystemFont,sans-serif;text-align:center;padding:24px;background:#0b0b0c}}
</style>
</head>
<body>
<div id="tcaptcha"></div>
<div id="fallback">验证码加载失败，请返回重试</div>
<script src="{script_url}"></script>
<script>
(function(){{
  function bridge(obj){{
    try {{
      if (window.TencentCaptchaBridge) {{
        window.TencentCaptchaBridge.postMessage(JSON.stringify(obj));
      }}
    }} catch (e) {{}}
  }}
  window.onload = function(){{
    try {{
      if (typeof TencentCaptcha !== 'function') throw new Error('script not loaded');
      {init_js}
    }} catch (e) {{
      document.getElementById('fallback').style.display='flex';
      bridge({{ret:-1,errorMessage:String(e && e.message || e)}});
    }}
  }};
}})();
</script>
</body>
</html>"""
