# -*- coding: utf-8 -*-
"""下载 ticket：主服务签发，下载网关校验；不泄露网盘原始地址。"""
import os
import json
import time
import hmac
import base64
import hashlib

TICKET_TTL = int(os.environ.get("APP_TICKET_TTL", "1800"))


def _secret():
    raw = (os.environ.get("APP_TICKET_SECRET") or "").strip()
    if len(raw) < 32:
        raise RuntimeError("APP_TICKET_SECRET 未配置或长度不足 32")
    return raw.encode("utf-8")


def _b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _unb64(data):
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))


def issue(version_id, app_id, ttl=None):
    payload = {"v": version_id, "a": app_id, "exp": int(time.time()) + int(ttl or TICKET_TTL)}
    raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    data = _b64(raw)
    sig = hmac.new(_secret(), data.encode("ascii"), hashlib.sha256).hexdigest()
    return data + "." + sig


def verify(ticket):
    """有效返回 payload，失败返回 None。"""
    try:
        data, sig = (ticket or "").split(".", 1)
        expect = hmac.new(_secret(), data.encode("ascii"), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expect, sig):
            return None
        payload = json.loads(_unb64(data).decode("utf-8"))
        if not payload.get("v") or not payload.get("a"):
            return None
        if int(payload.get("exp") or 0) < int(time.time()):
            return None
        return payload
    except Exception:
        return None


def internal_token():
    return (os.environ.get("APP_INTERNAL_TOKEN") or "").strip()
