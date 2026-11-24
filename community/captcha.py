# -*- coding: utf-8 -*-
"""流萤社区 · 自托管人机验证（滑块为主，图片验证码兼容旧客户端）。

- 滑块：使用开源 go-captcha-py（Apache-2.0）生成拼图背景与滑块，不依赖任何
  第三方账号或密钥。答案（缺口坐标）只存服务端 SQLite，成功即删除；5 分钟
  有效、最多 5 次错误，配合发码接口的 IP/账号限流。
- 图片：保留旧版 4 位字符挑战，供尚未升级的 App 使用。`GET /captcha` 同时
  返回 `image` 和滑块字段，两套挑战共用同一个 id，客户端按自身能力选择。
- 腾讯：配置完整时优先腾讯票据校验；否则走自托管挑战。

前端只拿到图片和初始滑块位置，拿不到目标 x；提交时回传滑块最终左侧坐标，
服务端按容差校验。
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import io
import os
import random
import secrets
import time
import json
import urllib.error
import urllib.request

SLIDER_TTL = 300
SLIDER_MAX_ATTEMPTS = 5
SLIDER_TOLERANCE = 6

IMAGE_TTL = 300
IMAGE_MAX_ATTEMPTS = 5
IMAGE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

_SECRET_CACHE = None


def _secret() -> bytes:
    """图片挑战签名密钥：优先环境变量，否则落盘到 files/.captcha_secret。"""
    global _SECRET_CACHE
    if _SECRET_CACHE is not None:
        return _SECRET_CACHE
    env = (os.environ.get("COMMUNITY_CAPTCHA_SECRET") or "").strip()
    if env:
        _SECRET_CACHE = env.encode("utf-8")
        return _SECRET_CACHE
    # 密钥文件必须放在非 Web 可读目录；不要放 files/ 下。
    path = (os.environ.get("COMMUNITY_CAPTCHA_SECRET_FILE") or "").strip() \
        or "/www/wwwroot/yosar-data/config/captcha_secret"
    try:
        with open(path, "rb") as f:
            val = f.read().strip()
        if len(val) >= 32:
            _SECRET_CACHE = val
            return val
    except Exception:
        pass
    val = secrets.token_bytes(32)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(val)
        try:
            os.chmod(path, 0o600)
        except Exception:
            pass
    except Exception:
        pass
    _SECRET_CACHE = val
    return val


def _answer_hash(cid: str, answer: str) -> str:
    return hmac.new(_secret(), ("captcha:%s:%s" % (cid, answer)).encode("utf-8"),
                    hashlib.sha256).hexdigest()


# ---------- 滑块挑战 ----------

def _ensure(c):
    c.execute("""CREATE TABLE IF NOT EXISTS community_slider_captchas(
        id TEXT PRIMARY KEY,
        answer_x REAL NOT NULL,
        answer_y REAL NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        tile_x REAL NOT NULL,
        tile_y REAL NOT NULL,
        piece_width INTEGER NOT NULL,
        piece_height INTEGER NOT NULL,
        ip TEXT DEFAULT '',
        created REAL NOT NULL,
        expires REAL NOT NULL,
        attempts INTEGER DEFAULT 0
    )""")


def _cleanup(c, now):
    c.execute("DELETE FROM community_slider_captchas WHERE expires<?",
              (now - 60,))


def _issue_slider(c, ip: str, cid: str) -> dict:
    """生成滑动拼图挑战，答案只落库，不返回前端。"""
    from go_captcha_py import slide

    capt = slide.make_default_captcha()
    data = capt.generate()
    block = data.get_data()
    master_obj = data.get_master_image()
    tile_obj = data.get_tile_image()
    master = master_obj.get()
    tile = tile_obj.get()
    width, height = master.size
    piece_width, piece_height = tile.size

    _ensure(c)
    now = time.time()
    _cleanup(c, now)
    c.execute(
        "INSERT INTO community_slider_captchas(id,answer_x,answer_y,width,height,"
        "tile_x,tile_y,piece_width,piece_height,ip,created,expires,attempts) "
        "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,0)",
        (cid, float(block.x), float(block.y), int(width), int(height),
         float(block.tile_x), float(block.tile_y), int(piece_width),
         int(piece_height), (ip or "")[:64], now, now + SLIDER_TTL),
    )
    c.commit()
    return {
        "id": cid,
        "type": "slider",
        "bg": "data:image/jpeg;base64," + master_obj.to_base64(),
        "tile": "data:image/png;base64," + tile_obj.to_base64(),
        "width": int(width),
        "height": int(height),
        "y": float(block.y),
        "tile_x": float(block.tile_x),
        "tile_y": float(block.tile_y),
        "piece_width": int(piece_width),
        "piece_height": int(piece_height),
        "expires": SLIDER_TTL,
        "_debug_x": float(block.x),
        "_debug_y": float(block.y),
    }


def _verify_slider(c, cid: str, x, y=None) -> tuple[bool, str]:
    """校验滑块最终左侧坐标。返回 (ok, error_code)。"""
    cid = str(cid or "").strip()
    if not cid or len(cid) > 80:
        return False, "slider_required"
    try:
        sx = float(x)
    except Exception:
        return False, "slider_required"
    sy = None
    if y not in (None, ""):
        try:
            sy = float(y)
        except Exception:
            return False, "slider_required"

    _ensure(c)
    now = time.time()
    row = c.execute(
        "SELECT answer_x,answer_y,expires,attempts FROM community_slider_captchas "
        "WHERE id=?", (cid,)).fetchone()
    if not row:
        return False, "slider_expired"
    if now > (row[2] or 0):
        c.execute("DELETE FROM community_slider_captchas WHERE id=?", (cid,))
        c.commit()
        return False, "slider_expired"
    if int(row[3] or 0) >= SLIDER_MAX_ATTEMPTS:
        c.execute("DELETE FROM community_slider_captchas WHERE id=?", (cid,))
        c.commit()
        return False, "slider_too_many"

    ok_x = abs(sx - float(row[0])) <= SLIDER_TOLERANCE
    ok_y = sy is None or abs(sy - float(row[1])) <= SLIDER_TOLERANCE
    if ok_x and ok_y:
        c.execute("DELETE FROM community_slider_captchas WHERE id=?", (cid,))
        c.commit()
        return True, ""

    attempts = int(row[3] or 0) + 1
    if attempts >= SLIDER_MAX_ATTEMPTS:
        c.execute("DELETE FROM community_slider_captchas WHERE id=?", (cid,))
    else:
        c.execute("UPDATE community_slider_captchas SET attempts=? WHERE id=?",
                  (attempts, cid))
    c.commit()
    return False, "slider_invalid"


# ---------- 图片挑战（旧客户端兼容） ----------

def _ensure_image(c):
    c.execute("""CREATE TABLE IF NOT EXISTS community_captchas(
        id TEXT PRIMARY KEY,
        code_hash TEXT NOT NULL,
        ip TEXT DEFAULT '',
        created REAL NOT NULL,
        expires REAL NOT NULL,
        attempts INTEGER DEFAULT 0
    )""")


def _cleanup_image(c, now):
    c.execute("DELETE FROM community_captchas WHERE expires<?", (now - 60,))


def _render_image(code: str) -> bytes:
    from PIL import Image, ImageDraw, ImageFont

    w, h = 150, 52
    img = Image.new("RGB", (w, h), (247, 244, 233))
    draw = ImageDraw.Draw(img)
    for _ in range(7):
        draw.line(
            [(random.randint(0, w), random.randint(0, h)),
             (random.randint(0, w), random.randint(0, h))],
            fill=(random.randint(120, 200), random.randint(120, 200),
                  random.randint(120, 200)),
            width=1,
        )
    for _ in range(70):
        draw.point(
            (random.randint(0, w), random.randint(0, h)),
            fill=(random.randint(80, 210), random.randint(80, 210),
                  random.randint(80, 210)),
        )
    font = None
    for path in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
        "/usr/share/fonts/truetype/freefont/FreeSansBold.ttf",
    ):
        try:
            font = ImageFont.truetype(path, 30)
            break
        except Exception:
            continue
    if font is None:
        try:
            font = ImageFont.load_default(size=30)
        except TypeError:
            font = ImageFont.load_default()
    for i, ch in enumerate(code):
        x = 14 + i * 32 + random.randint(-2, 2)
        y = 7 + random.randint(-3, 4)
        draw.text((x, y), ch, font=font,
                  fill=(random.randint(20, 80), random.randint(40, 100),
                        random.randint(50, 110)))
    img = img.rotate(-2.5, resample=Image.BILINEAR, fillcolor=(247, 244, 233))
    out = io.BytesIO()
    img.save(out, "PNG", optimize=True)
    return out.getvalue()


def _issue_image(c, ip: str, cid: str) -> dict:
    _ensure_image(c)
    now = time.time()
    _cleanup_image(c, now)
    code = "".join(secrets.choice(IMAGE_CHARS) for _ in range(4))
    c.execute(
        "INSERT INTO community_captchas(id,code_hash,ip,created,expires,attempts) "
        "VALUES(?,?,?,?,?,0)",
        (cid, _answer_hash(cid, code), (ip or "")[:64], now, now + IMAGE_TTL),
    )
    c.commit()
    png = _render_image(code)
    return {
        "image": "data:image/png;base64," + base64.b64encode(png).decode("ascii"),
        "_debug_code": code,
    }


def _verify_image(c, cid: str, answer: str) -> tuple[bool, str]:
    cid = str(cid or "").strip()
    answer = "".join(ch for ch in str(answer or "").strip().upper() if ch.isalnum())
    if not cid or len(cid) > 80 or not answer:
        return False, "captcha_required"
    _ensure_image(c)
    now = time.time()
    row = c.execute(
        "SELECT code_hash,expires,attempts FROM community_captchas WHERE id=?",
        (cid,)).fetchone()
    if not row:
        return False, "captcha_expired"
    if now > (row[1] or 0):
        c.execute("DELETE FROM community_captchas WHERE id=?", (cid,))
        c.commit()
        return False, "captcha_expired"
    if int(row[2] or 0) >= IMAGE_MAX_ATTEMPTS:
        c.execute("DELETE FROM community_captchas WHERE id=?", (cid,))
        c.commit()
        return False, "captcha_too_many"
    if not hmac.compare_digest(row[0], _answer_hash(cid, answer)):
        attempts = int(row[2] or 0) + 1
        if attempts >= IMAGE_MAX_ATTEMPTS:
            c.execute("DELETE FROM community_captchas WHERE id=?", (cid,))
        else:
            c.execute("UPDATE community_captchas SET attempts=? WHERE id=?",
                      (attempts, cid))
        c.commit()
        return False, "captcha_invalid"
    c.execute("DELETE FROM community_captchas WHERE id=?", (cid,))
    c.commit()
    return True, ""


def _drop_other(c, table: str, cid: str):
    try:
        c.execute("DELETE FROM %s WHERE id=?" % table, (cid,))
        c.commit()
    except Exception:
        pass


# ---------- Cap 本机服务 ----------

CAP_SERVICE_URL = os.environ.get(
    "COMMUNITY_CAP_SERVICE", "http://127.0.0.1:8791").rstrip("/")


def _cap_call(path: str, payload: dict, timeout: float = 12.0):
    """调用只监听本机的 Cap 服务；失败返回 None，由调用方 fail-closed。"""
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        CAP_SERVICE_URL + path, data=data,
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return None
            return json.loads(resp.read(2 * 1024 * 1024).decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, ValueError, OSError):
        return None


def cap_challenge() -> dict | None:
    data = _cap_call("/challenge", {})
    if not isinstance(data, dict) or not data.get("token") or not data.get("challenges"):
        return None
    return data


def cap_redeem(body: dict) -> dict:
    data = _cap_call("/redeem", body)
    if not isinstance(data, dict):
        return {"success": False, "error": "安全验证服务暂不可用，请稍后重试"}
    return data


def cap_validate(token: str) -> bool:
    token = str(token or "").strip()
    if not token or len(token) > 200:
        return False
    data = _cap_call("/validate", {"token": token})
    return bool(data and data.get("success") is True)


def _legacy_client_allowed(handler) -> bool:
    """旧版 Flutter App 的滑块/图片兼容通道。

    默认关闭：Cap 才是面向浏览器和新 App 的真人验证；旧协议可被伪造
    Dart UA 的自动化脚本复用，不能作为生产兜底。仅在明确设置
    COMMUNITY_CAPTCHA_LEGACY=1 时开启，用于本地旧客户端回归测试。
    """
    if os.environ.get("COMMUNITY_CAPTCHA_LEGACY", "0") != "1":
        return False
    from common import rate_limit_key
    ua = (handler.headers.get("User-Agent", "") or "")
    if "Dart/" not in ua:
        return False
    return rate_limit_key(handler, "captcha_legacy", "legacy", 6, 1800)


# ---------- 统一签发 / 校验 ----------

def issue(c, ip: str = "") -> dict:
    """签发一次挑战：滑块字段 + 旧客户端需要的图片字段，共用同一个 id。"""
    cid = secrets.token_urlsafe(18)
    slider = _issue_slider(c, ip, cid)
    image = _issue_image(c, ip, cid)
    dx = slider.pop("_debug_x", None)
    dy = slider.pop("_debug_y", None)
    code = image.pop("_debug_code", None)
    data = dict(slider)
    data["image"] = image["image"]
    # 仅测试进程可通过环境变量回传答案；生产环境不设置该变量。
    if os.environ.get("COMMUNITY_CAPTCHA_DEBUG") == "1":
        data["debug_x"] = dx
        data["debug_y"] = dy
        data["debug_code"] = code
    return data


def verify(c, cid: str, x, y=None) -> tuple[bool, str]:
    """滑块校验（保留旧调用签名）。"""
    return _verify_slider(c, cid, x, y)


def require(handler, c, body) -> bool:
    """业务入口统一调用；失败时已经写入 HTTP 错误响应。

    优先级：Cap 一次性 token → 腾讯（配置完整时）→ 旧版滑块/图片。
    旧版协议只允许 Flutter/Dart 客户端，并限制 6 次/30 分钟/IP；
    浏览器端必须走 Cap，不能通过提交 captcha_x 绕过。
    """
    import tencent_captcha

    body = body or {}
    cap_token = str(body.get("cap_token") or "").strip()
    if cap_token:
        if cap_validate(cap_token):
            return True
        handler._err(400, "安全验证已失效，请重新验证")
        return False

    if tencent_captcha.enabled():
        try:
            from common import client_ip
            ip = client_ip(handler)
        except Exception:
            ip = ""
        ok, msg = tencent_captcha.verify(
            c,
            body.get("captcha_ticket") or "",
            body.get("captcha_randstr") or "",
            ip,
        )
        if ok:
            return True
        handler._err(400, msg or "人机验证失败，请重试")
        return False

    if body.get("captcha_x") in (None, "") and body.get("captcha_code") in (None, ""):
        handler._err(400, "请先完成安全验证")
        return False

    if not _legacy_client_allowed(handler):
        ua = (handler.headers.get("User-Agent", "") or "")
        if "Dart/" in ua:
            handler._err(400, "当前版本安全验证已升级，请更新 App 后重试")
        else:
            handler._err(400, "请刷新页面后重新完成安全验证")
        return False

    cid = body.get("captcha_id")
    if body.get("captcha_x") not in (None, ""):
        ok, err = _verify_slider(c, cid, body.get("captcha_x"),
                                 body.get("captcha_y"))
        if ok:
            _drop_other(c, "community_captchas", str(cid or ""))
            return True
        msg = {
            "slider_required": "请完成滑块验证",
            "slider_expired": "滑块验证已过期，请重试",
            "slider_too_many": "滑块验证失败次数过多，请重试",
            "slider_invalid": "拼图位置不对，请重试",
        }.get(err, "人机验证失败，请重试")
        handler._err(400, msg)
        return False

    if body.get("captcha_code") not in (None, ""):
        ok, err = _verify_image(c, cid, body.get("captcha_code"))
        if ok:
            _drop_other(c, "community_slider_captchas", str(cid or ""))
            return True
        msg = {
            "captcha_required": "请输入图片验证码",
            "captcha_expired": "人机验证已过期，请换一张",
            "captcha_too_many": "人机验证错误次数过多，请换一张",
            "captcha_invalid": "人机验证码错误，请重试",
        }.get(err, "人机验证失败，请重试")
        handler._err(400, msg)
        return False

    handler._err(400, "请完成安全验证")
    return False
