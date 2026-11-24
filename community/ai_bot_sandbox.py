# -*- coding: utf-8 -*-
"""流小萤 · 沙箱联网。

AI 的应用发现优先在自己的云沙箱里执行 curl，沙箱忙时再退回受控的
服务端抓取。沙箱只用于读取公开页面/公开 API，不执行用户输入的命令。
"""
import base64
import json
import shlex
import threading
import time
import urllib.error
import urllib.request

import af_sandbox as SB
from core.security import validate_outbound_url

BOT_ID = "ai_liuying_comment"
UA = "LiuyingCommunityBot/1.0 (+https://www.yosar.cloud)"
MAX_TEXT = 900_000
MAX_BYTES = 12 * 1024 * 1024
_LOCK = threading.Lock()
_ACTIVE = False


def status():
    try:
        return SB.status()
    except Exception as e:
        return {"ok": False, "error": str(e)[:160]}


def available():
    st = status()
    if not st.get("ok"):
        return False, st.get("error") or "sandbox offline"
    try:
        running = int(st.get("running") or 0)
        maximum = int(st.get("max") or 0)
        if maximum and running >= maximum:
            return False, "sandbox busy %d/%d" % (running, maximum)
    except Exception:
        pass
    return True, ""


def open_session():
    global _ACTIVE
    ok, err = available()
    if not ok:
        return False, err
    with _LOCK:
        r = SB.ensure(BOT_ID, net=True)
        if not r.get("ok"):
            return False, str(r.get("error") or "ensure failed")[:160]
        _ACTIVE = True
        return True, "sandbox"


def close_session():
    global _ACTIVE
    with _LOCK:
        if not _ACTIVE:
            return
        try:
            SB.destroy(BOT_ID)
        except Exception:
            pass
        _ACTIVE = False


def _assert_public(url):
    if not url or not str(url).startswith(("https://", "http://")):
        raise ValueError("bad url")
    ok, reason = validate_outbound_url(str(url))
    if not ok:
        raise ValueError("outbound blocked: " + reason)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _direct_open(url, timeout=35):
    """受控直连：每一跳都校验公网地址，禁止跳到内网/本机。"""
    current = str(url)
    opener = urllib.request.build_opener(_NoRedirect)
    for _ in range(4):
        _assert_public(current)
        req = urllib.request.Request(current, headers={"User-Agent": UA, "Accept": "*/*"})
        try:
            return opener.open(req, timeout=timeout)
        except urllib.error.HTTPError as e:
            if e.code in (301, 302, 303, 307, 308) and e.headers.get("Location"):
                current = urllib.parse.urljoin(current, e.headers["Location"])
                continue
            raise
    raise ValueError("too many redirects")


def _direct_text(url, max_bytes=MAX_TEXT, timeout=35):
    with _direct_open(url, timeout=timeout) as r:
        raw = r.read(max_bytes + 1)
        if len(raw) > max_bytes:
            raise ValueError("响应过大")
        return raw.decode("utf-8", "ignore")


def fetch_text(url, max_bytes=MAX_TEXT, timeout=35):
    """返回 (text, meta)。meta.source = sandbox / direct / failed。"""
    try:
        _assert_public(url)
    except Exception as e:
        return "", {"ok": False, "source": "failed", "error": str(e)[:160]}
    ok, err = open_session()
    if ok:
        try:
            cmd = ("curl -fsSL --max-time %d -A %s %s | head -c %d" %
                   (max(5, min(60, int(timeout))), shlex.quote(UA),
                    shlex.quote(url), int(max_bytes)))
            r = SB.exec_cmd(BOT_ID, cmd, timeout + 20)
            if r.get("ok"):
                return (r.get("out") or "")[:max_bytes], {"ok": True, "source": "sandbox",
                                                           "code": r.get("code")}
            err = str(r.get("error") or "curl failed")[:160]
        except Exception as e:
            err = str(e)[:160]
        finally:
            close_session()
    # 沙箱忙/不可用时，用服务端受控抓取兜底，保证 AI 仍能发现内容。
    try:
        return _direct_text(url, max_bytes=max_bytes, timeout=timeout), {
            "ok": True, "source": "direct", "fallback": err}
    except Exception as e:
        return "", {"ok": False, "source": "failed", "error": str(e)[:160], "fallback": err}


def fetch_json(url, max_bytes=MAX_TEXT, timeout=35):
    text, meta = fetch_text(url, max_bytes=max_bytes, timeout=timeout)
    if not text:
        return None, meta
    try:
        return json.loads(text), meta
    except Exception as e:
        meta = dict(meta or {})
        meta.update({"ok": False, "error": "json:" + str(e)[:100]})
        return None, meta


def fetch_bytes(url, max_bytes=MAX_BYTES, timeout=60):
    """小文件读取：优先沙箱下载再拉回，失败后走服务端受控抓取。"""
    try:
        _assert_public(url)
    except Exception as e:
        return None, {"ok": False, "error": str(e)[:160]}
    ok, err = open_session()
    if ok:
        path = "/work/.aibot_fetch_%d" % int(time.time() * 1000)
        try:
            cmd = ("curl -fsSL --max-time %d -A %s %s -o %s && stat -c %%s %s" %
                   (max(5, min(90, int(timeout))), shlex.quote(UA),
                    shlex.quote(url), shlex.quote(path), shlex.quote(path)))
            r = SB.exec_cmd(BOT_ID, cmd, timeout + 20)
            if r.get("ok"):
                try:
                    size = int((r.get("out") or "0").strip().splitlines()[-1])
                except Exception:
                    size = 0
                if 0 < size <= max_bytes:
                    p = SB.pull(BOT_ID, path)
                    if p.get("ok") and p.get("b64"):
                        return base64.b64decode(p["b64"]), {"ok": True, "source": "sandbox",
                                                            "size": size}
            err = str(r.get("error") or "download failed")[:160]
        except Exception as e:
            err = str(e)[:160]
        finally:
            try:
                if ok:
                    SB.exec_cmd(BOT_ID, "rm -f " + shlex.quote(path), 10)
            except Exception:
                pass
            close_session()
    try:
        with _direct_open(url, timeout=timeout) as r:
            raw = r.read(max_bytes + 1)
            if len(raw) > max_bytes:
                raise ValueError("文件过大")
            return raw, {"ok": True, "source": "direct", "fallback": err}
    except Exception as e:
        return None, {"ok": False, "error": str(e)[:160], "fallback": err}
