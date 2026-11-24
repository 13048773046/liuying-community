# -*- coding: utf-8 -*-
"""流萤社区 · 易支付（epay）对接。

商户参数复用流萤音乐项目后台「支付设置」的配置（同机部署，单一数据源）：
    /www/wwwroot/music/config/site_config.json
字段：pay_enabled / pay_merchant_id / pay_merchant_key / pay_gateway

协议：易支付官方文档（https://payke.cn/doc/v1_legacy_api.html）
    API 接口支付：POST {gateway}/mapi.php（返回 payurl，App 用 WebView 打开）
    MD5 签名：除 sign/sign_type 外的非空参数按 key 字典序拼 k=v&k=v，末尾直接拼商户密钥，md5 小写
    回调 GET/POST，验签同上，trade_status=TRADE_SUCCESS
    App 内 WebView 打开 mapi 返回的 payurl；支付结果由 notify_url 异步回调落库。
"""
import hashlib
import hmac
import json
import os
import threading
import time
import urllib.parse
import urllib.request

MUSIC_SITE_CONFIG = os.environ.get(
    "MUSIC_SITE_CONFIG", "/www/wwwroot/music/config/site_config.json"
)
# 后台 H5「支付设置」写入的独立配置；存在时覆盖音乐站配置（不动音乐项目）
COMMUNITY_CFG = os.environ.get(
    "COMMUNITY_EPAY_CONFIG",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "epay_config.json"),
)
CACHE_TTL = 30
_lock = threading.Lock()
_cache = {"t": 0, "cfg": None}


class EpayError(Exception):
    pass


def settings(force=False):
    """读取易支付配置（30s 缓存）。返回 dict：enabled/pid/key/gateway。"""
    now = time.time()
    with _lock:
        if not force and _cache["cfg"] is not None and now - _cache["t"] < CACHE_TTL:
            return dict(_cache["cfg"])
    cfg = {"enabled": False, "pid": "", "key": "", "gateway": ""}
    # 1) 社区后台保存的配置优先
    try:
        with open(COMMUNITY_CFG, "r", encoding="utf-8") as f:
            own = json.load(f)
        if isinstance(own, dict) and (own.get("pid") or own.get("key") or own.get("gateway")):
            cfg = {
                "enabled": bool(own.get("enabled")),
                "pid": str(own.get("pid") or "").strip(),
                "key": str(own.get("key") or "").strip(),
                "gateway": str(own.get("gateway") or "").strip(),
            }
    except Exception:
        pass
    # 2) 没填过则复用音乐项目后台的支付设置
    if not (cfg["pid"] and cfg["key"] and cfg["gateway"]):
        try:
            with open(MUSIC_SITE_CONFIG, "r", encoding="utf-8") as f:
                raw = json.load(f)
            cfg = {
                "enabled": bool(raw.get("pay_enabled")),
                "pid": str(raw.get("pay_merchant_id") or "").strip(),
                "key": str(raw.get("pay_merchant_key") or "").strip(),
                "gateway": str(raw.get("pay_gateway") or "").strip(),
            }
        except Exception:
            pass
    # 环境变量可覆盖（便于灰度/换商户，不用改音乐配置）
    cfg["pid"] = os.environ.get("EPAY_PID", cfg["pid"])
    cfg["key"] = os.environ.get("EPAY_KEY", cfg["key"])
    cfg["gateway"] = os.environ.get("EPAY_GATEWAY", cfg["gateway"])
    cfg["enabled"] = bool(cfg["pid"] and cfg["key"] and cfg["gateway"]) and (
        cfg["enabled"] or bool(os.environ.get("EPAY_FORCE"))
    )
    with _lock:
        _cache["t"] = now
        _cache["cfg"] = cfg
    return dict(cfg)


def sign(params, key):
    """易支付 MD5 签名（小写）。"""
    pairs = []
    for k in sorted(params.keys()):
        if k in ("sign", "sign_type"):
            continue
        v = params.get(k)
        if v is None:
            continue
        v = str(v)
        if v == "":
            continue
        pairs.append("%s=%s" % (k, v))
    raw = "&".join(pairs) + key
    return hashlib.md5(raw.encode("utf-8")).hexdigest().lower()


def verify(params, key):
    got = str(params.get("sign") or "").lower()
    if not got:
        return False
    return hmac.compare_digest(sign(params, key), got)


def gateway_base(gateway):
    """规范化网关根地址，兼容后台误填 /submit.php 或具体 php 文件。"""
    gw = (gateway or "").strip().rstrip("/")
    if gw.endswith("/submit.php"):
        gw = gw[:-len("/submit.php")]
    elif gw.endswith(".php"):
        gw = gw.rsplit("/", 1)[0]
    return gw


def _clip_name(name, limit=120):
    raw = str(name or "流萤社区会员").strip()
    b = raw.encode("utf-8")[:limit]
    return b.decode("utf-8", "ignore")


def _post_form(url, params, timeout=15):
    body = urllib.parse.urlencode(params).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8", "replace")
    try:
        return json.loads(raw)
    except Exception:
        raise EpayError("网关返回异常：%s" % raw[:120])


def create(order_no, money_fen, name, channel, client_ip, notify_url, return_url):
    """调用官方 API 接口支付（mapi.php）创建支付链接。

    官方文档：https://pay.imataoke.com/doc.html
    返回 {trade_no, pay_type, pay_info}；pay_type 为 jump 时 App 用 WebView 打开 pay_info。
    """
    cfg = settings()
    if not cfg["enabled"]:
        raise EpayError("支付未启用，请在后台支付设置中开启")
    if channel not in ("wxpay", "alipay"):
        raise EpayError("不支持的支付方式")
    if not (cfg["pid"] and cfg["key"] and cfg["gateway"]):
        raise EpayError("支付参数不完整，请在后台支付设置中填写商户 ID、密钥和网关")
    params = {
        "pid": cfg["pid"],
        "type": channel,
        "out_trade_no": order_no,
        "notify_url": notify_url,
        "return_url": return_url,
        "name": _clip_name(name),
        "money": "%.2f" % (int(money_fen) / 100.0),
        "clientip": client_ip or "127.0.0.1",
        "device": "mobile",
    }
    params["sign"] = sign(params, cfg["key"])
    params["sign_type"] = "MD5"
    try:
        data = _post_form(gateway_base(cfg["gateway"]) + "/mapi.php", params, timeout=12)
    except EpayError:
        raise
    except Exception as e:
        raise EpayError("支付网关连接失败：%s" % e)
    if int(data.get("code") or 0) != 1:
        raise EpayError(str(data.get("msg") or "下单失败"))
    pay_url = str(data.get("payurl") or "").strip()
    scheme = str(data.get("urlscheme") or "").strip()
    qrcode = str(data.get("qrcode") or "").strip()
    if pay_url.startswith("//"):
        pay_url = "https:" + pay_url
    elif pay_url.startswith("/"):
        pay_url = gateway_base(cfg["gateway"]) + pay_url
    if pay_url:
        pay_type, pay_info = "jump", pay_url
    elif scheme:
        pay_type, pay_info = "scheme", scheme
    elif qrcode:
        pay_type, pay_info = "qrcode", qrcode
    else:
        raise EpayError("网关未返回支付链接")
    return {
        "trade_no": str(data.get("trade_no") or ""),
        "pay_type": pay_type,
        "pay_info": pay_info,
    }


def save(patch):
    """后台保存支付设置；key 传空表示保持现有密钥。返回最新配置（key 已脱敏）。"""
    cur = settings(force=True)
    old = {}
    try:
        with open(COMMUNITY_CFG, "r", encoding="utf-8") as f:
            old = json.load(f) or {}
    except Exception:
        old = {}
    enabled = bool(patch.get("enabled", cur["enabled"]))
    pid = str(patch.get("pid", cur["pid"]) or "").strip()
    gateway = str(patch.get("gateway", cur["gateway"]) or "").strip()
    key = str(patch.get("key") or "").strip() or str(old.get("key") or cur["key"] or "").strip()
    if pid and not pid.isdigit():
        raise EpayError("商户 ID 只能是数字")
    if gateway:
        parsed = urllib.parse.urlsplit(gateway)
        if parsed.scheme not in ("http", "https") or not parsed.hostname:
            raise EpayError("网关地址需以 http:// 或 https:// 开头")
        if parsed.scheme != "https" and parsed.hostname not in ("localhost", "127.0.0.1", "::1"):
            raise EpayError("支付网关必须使用 HTTPS，只有本机调试地址允许 HTTP")
    data = {"enabled": enabled, "pid": pid, "key": key, "gateway": gateway}
    with open(COMMUNITY_CFG, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    try:
        os.chmod(COMMUNITY_CFG, 0o600)
    except Exception:
        pass
    settings(force=True)
    return settings(force=True)


def probe():
    """查询商户信息，验证网关、pid、key 是否有效（不会产生订单）。"""
    cfg = settings()
    if not (cfg["pid"] and cfg["key"] and cfg["gateway"]):
        return {"ok": False, "msg": "参数不完整，请先填写商户 ID、密钥和网关"}
    base = gateway_base(cfg["gateway"])
    url = base + "/api.php?" + urllib.parse.urlencode(
        {"act": "query", "pid": cfg["pid"], "key": cfg["key"]}
    )
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read().decode("utf-8", "replace")
        data = json.loads(raw)
    except Exception as e:
        return {"ok": False, "msg": "网关连接失败：%s" % e}
    if int(data.get("code") or -1) != 1:
        return {"ok": False, "msg": str(data.get("msg") or "商户信息校验失败")}
    if int(data.get("active") or 0) != 1:
        return {"ok": False, "msg": "商户已被停用，请检查易支付商户后台"}
    return {"ok": True, "msg": "商户信息有效，网关可访问；能否收款以商户后台审核状态为准"}
