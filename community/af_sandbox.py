# -*- coding: utf-8 -*-
"""流萤工坊 · A 侧沙箱客户端。

A → B 走反向隧道（B 主动 ssh -R 到 A 的 127.0.0.1:8791），
请求带 HMAC 签名，B 只接受本地隧道来的调用。
"""
import hashlib
import hmac
import json
import os
import urllib.request

SB_URL = "http://127.0.0.1:8791"
SB_SECRET = os.environ.get("AF_SANDBOX_SECRET", "").strip()


class SandboxError(Exception):
    pass


def _call(path, payload, timeout=200):
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    sig = hmac.new(SB_SECRET.encode(), body, hashlib.sha256).hexdigest()
    req = urllib.request.Request(
        SB_URL + path, data=body,
        headers={"Content-Type": "application/json", "X-Sig": sig}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception as e:
        return {"ok": False, "error": "sb_unreachable:" + str(e)[:120]}


def status():
    try:
        with urllib.request.urlopen(SB_URL + "/sb/status", timeout=8) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception as e:
        return {"ok": False, "error": str(e)[:120]}


def ensure(uid, net=False):
    return _call("/sb/ensure", {"uid": uid, "net": bool(net)}, timeout=120)


def exec_cmd(uid, cmd, timeout=120):
    return _call("/sb/exec", {"uid": uid, "cmd": cmd, "timeout": int(timeout)}, timeout=int(timeout) + 20)


def pull(uid, path):
    return _call("/sb/pull", {"uid": uid, "path": path}, timeout=120)


def put(uid, path, b64):
    return _call("/sb/put", {"uid": uid, "path": path, "b64": b64}, timeout=120)


def destroy(uid):
    return _call("/sb/destroy", {"uid": uid}, timeout=90)
