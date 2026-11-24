# -*- coding: utf-8 -*-
"""流小萤 · 模型、联网素材与媒体处理。

只做三件事：
1) 调文本/视觉模型（复用音乐后台已有的 AI 配置，不新增明文 Key）；
2) 从 Wikimedia Commons / Openverse 取开放许可图片、从 Wikimedia 取短视频；
3) 图片校验、压缩、视频转码、抽帧。
所有外链下载都限制公网 https、大小、类型，防 SSRF 与超大文件。
"""
import base64
import io
import ipaddress
import json
import os
import re
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from PIL import Image, ImageOps

BASE = os.path.dirname(os.path.abspath(__file__))
FILES_DIR = os.path.join(BASE, "files")
MUSIC_AI_CFG = "/www/wwwroot/music/config/ai_config.json"
UA = "LiuyingCommunityBot/1.0 (+https://www.yosar.cloud)"
VISION_MODEL = "Qwen/Qwen3-VL-32B-Instruct"
MAX_IMAGE_BYTES = 18 * 1024 * 1024
MAX_VIDEO_BYTES = 60 * 1024 * 1024
MAX_VIDEO_SECONDS = 62


# ---------------- 配置 / HTTP --------------
def _cfg():
    try:
        with open(MUSIC_AI_CFG, encoding="utf-8") as f:
            return json.loads(f.read() or "{}")
    except Exception:
        return {}


def _post_json(base, key, path, body, timeout=60):
    url = base.rstrip("/") + path
    req = urllib.request.Request(
        url, data=json.dumps(body).encode("utf-8"),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json",
                 "User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def _chat(cfg_key, model, messages, max_tokens=600, temperature=0.4, timeout=75):
    cfg = _cfg()
    c = cfg.get(cfg_key) or {}
    if not c.get("base") or not c.get("key"):
        raise RuntimeError("AI 配置缺失：" + cfg_key)
    body = {"model": model, "messages": messages, "max_tokens": max_tokens,
            "temperature": temperature}
    for _ in range(2):
        try:
            data = _post_json(c["base"], c["key"], "/chat/completions", body, timeout=timeout)
            msg = (data.get("choices") or [{}])[0].get("message") or {}
            content = (msg.get("content") or "").strip()
            if content:
                return content
        except Exception:
            time.sleep(1.2)
    return ""


def llm_text(system, user, max_tokens=700, temperature=0.45):
    """文本模型：DeepSeek 兼容端点。"""
    cfg = _cfg()
    chat = cfg.get("chat") or {}
    model = chat.get("model") or "deepseek-flash"
    return _chat("chat", model, [
        {"role": "system", "content": system},
        {"role": "user", "content": user},
    ], max_tokens=max_tokens, temperature=temperature)


def _prep_image(path, max_side=768):
    im = Image.open(path)
    im = ImageOps.exif_transpose(im)
    if im.mode != "RGB":
        im = im.convert("RGB")
    im.thumbnail((max_side, max_side), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=82)
    return buf.getvalue()


def llm_vision(prompt, image_paths, max_tokens=320):
    """视觉模型：Qwen3-VL（SiliconFlow，复用后台生图配置的 Key）。"""
    cfg = _cfg()
    img = cfg.get("image") or {}
    if not img.get("base") or not img.get("key"):
        return ""
    content = [{"type": "text", "text": prompt}]
    for p in image_paths[:4]:
        try:
            b64 = base64.b64encode(_prep_image(p, 768)).decode("ascii")
            content.append({"type": "image_url",
                            "image_url": {"url": "data:image/jpeg;base64," + b64}})
        except Exception:
            continue
    if len(content) == 1:
        return ""
    body = {"model": VISION_MODEL, "messages": [{"role": "user", "content": content}],
            "max_tokens": max_tokens, "temperature": 0.2}
    for _ in range(2):
        try:
            data = _post_json(img["base"], img["key"], "/chat/completions", body, timeout=90)
            msg = (data.get("choices") or [{}])[0].get("message") or {}
            return (msg.get("content") or "").strip()
        except Exception:
            time.sleep(1.5)
    return ""


def json_obj(text):
    """从模型输出里抽第一个 JSON 对象；失败返回 None。"""
    if not text:
        return None
    t = text.strip()
    if t.startswith("```"):
        t = re.sub(r"^```[a-zA-Z]*\s*", "", t)
        t = re.sub(r"\s*```$", "", t).strip()
    start = t.find("{")
    if start < 0:
        return None
    dec = json.JSONDecoder()
    try:
        obj, _ = dec.raw_decode(t[start:])
        return obj if isinstance(obj, dict) else None
    except Exception:
        return None


# ---------------- 安全下载 --------------
def _assert_public(url):
    p = urllib.parse.urlparse(url or "")
    if p.scheme not in ("http", "https") or not p.hostname:
        raise ValueError("链接不合法")
    if p.username or p.password:
        raise ValueError("链接不能带账号密码")
    host = p.hostname.lower().strip("[]")
    if host in ("localhost", "localhost.localdomain"):
        raise ValueError("不允许本机地址")
    try:
        infos = socket.getaddrinfo(host, None)
        for info in infos:
            ip = ipaddress.ip_address(info[4][0])
            if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved:
                raise ValueError("不允许内网地址")
    except socket.gaierror:
        raise ValueError("域名无法解析")


def fetch(url, max_bytes=MAX_IMAGE_BYTES, timeout=35, content_prefix=None, redirects=3):
    """流式下载，限制大小与公网地址；返回 (bytes, content_type, final_url)。"""
    class _NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    opener = urllib.request.build_opener(_NoRedirect)
    current = url
    for _ in range(redirects + 1):
        _assert_public(current)
        req = urllib.request.Request(current, headers={
            "User-Agent": UA, "Accept": "*/*"})
        try:
            r = opener.open(req, timeout=timeout)
        except urllib.error.HTTPError as e:
            if e.code in (301, 302, 303, 307, 308):
                loc = e.headers.get("Location") or ""
                if not loc:
                    raise
                current = urllib.parse.urljoin(current, loc)
                continue
            raise
        with r:
            ct = (r.headers.get("Content-Type") or "").split(";")[0].strip().lower()
            if content_prefix and ct and not ct.startswith(content_prefix):
                raise ValueError("内容类型不符：%s" % ct)
            length = r.headers.get("Content-Length")
            if length and int(length) > max_bytes:
                raise ValueError("文件超过大小限制")
            buf = bytearray()
            while True:
                chunk = r.read(64 * 1024)
                if not chunk:
                    break
                buf.extend(chunk)
                if len(buf) > max_bytes:
                    raise ValueError("文件超过大小限制")
            return bytes(buf), ct, r.geturl()
    raise ValueError("重定向过多")


# ---------------- 图片 --------------
def image_ok(data):
    try:
        im = Image.open(io.BytesIO(data))
        im.verify()
        return True
    except Exception:
        return False


def normalize_image(data, max_side=1600, square=False):
    im = Image.open(io.BytesIO(data))
    im = ImageOps.exif_transpose(im)
    if im.mode in ("RGBA", "LA", "P"):
        im = im.convert("RGBA")
        bg = Image.new("RGB", im.size, (255, 255, 255))
        bg.paste(im, mask=im.split()[-1])
        im = bg
    else:
        im = im.convert("RGB")
    if square:
        w, h = im.size
        side = min(w, h)
        im = im.crop(((w - side) // 2, (h - side) // 2,
                      (w + side) // 2, (h + side) // 2))
        im = im.resize((512, 512), Image.LANCZOS)
    else:
        im.thumbnail((max_side, max_side), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=88, optimize=True)
    return buf.getvalue()


def save_image(data, prefix="community_img_ai_liuyi_", square=False):
    os.makedirs(FILES_DIR, exist_ok=True)
    out = normalize_image(data, square=square)
    name = prefix + uuid.uuid4().hex[:14] + ".jpg"
    with open(os.path.join(FILES_DIR, name), "wb") as f:
        f.write(out)
    return name, "/community/api/media/" + name


def download_image(url, max_side=1600):
    data, ct, final = fetch(url, max_bytes=MAX_IMAGE_BYTES)
    if not image_ok(data):
        raise ValueError("图片损坏")
    im = Image.open(io.BytesIO(data))
    if im.width < 600:
        raise ValueError("图片宽度不足")
    return normalize_image(data, max_side=max_side)


def download_image_to_file(url, prefix="community_img_ai_liuyi_"):
    data = download_image(url)
    name, media = save_image(data, prefix=prefix)
    return name, media, os.path.join(FILES_DIR, name)


# ---------------- 短视频 --------------
def _ffprobe_duration(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                        "-of", "default=noprint_wrappers=1:nokey=1", path],
                       capture_output=True, timeout=30)
    return float((r.stdout or b"0").decode().strip() or 0)


def _run_ff(args, timeout=300):
    subprocess.run(args, capture_output=True, timeout=timeout, check=True)


def download_video(url):
    """下载并转成 1280 宽 H.264 MP4，返回 (video_id, cover_name, duration, mp4_path)。"""
    data, ct, final = fetch(url, max_bytes=MAX_VIDEO_BYTES, timeout=70)
    if not (ct or "").startswith("video/"):
        # Wikimedia 有时返回 application/octet-stream；交给 ffprobe 验证。
        pass
    ext = ".webm" if "webm" in (ct or "") else ".mp4"
    os.makedirs(FILES_DIR, exist_ok=True)
    tmp = os.path.join(FILES_DIR, "_ai_src_" + uuid.uuid4().hex[:10] + ext)
    with open(tmp, "wb") as f:
        f.write(data)
    try:
        dur = _ffprobe_duration(tmp)
        if not dur or dur > MAX_VIDEO_SECONDS:
            raise ValueError("视频时长不符合要求")
        vid = "community_video_ai_liuyi_" + uuid.uuid4().hex[:10]
        mp4 = os.path.join(FILES_DIR, vid + ".mp4")
        _run_ff(["ffmpeg", "-y", "-i", tmp, "-t", "60",
                 "-vf", "scale='min(1280,iw)':-2",
                 "-c:v", "libx264", "-preset", "veryfast", "-crf", "24",
                 "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", mp4])
        cover = os.path.join(FILES_DIR, vid + ".jpg")
        _run_ff(["ffmpeg", "-y", "-i", mp4, "-frames:v", "1", "-q:v", "3", cover])
        dur2 = _ffprobe_duration(mp4) or dur
        return vid, vid + ".jpg", dur2, mp4
    finally:
        try:
            os.remove(tmp)
        except Exception:
            pass


def extract_frames(mp4_path, count=3):
    outs = []
    dur = _ffprobe_duration(mp4_path) or 1
    for i in range(count):
        t = max(0.2, dur * (0.15 + 0.35 * i))
        p = mp4_path + ".frame%d.jpg" % i
        try:
            _run_ff(["ffmpeg", "-y", "-ss", "%.2f" % t, "-i", mp4_path,
                     "-frames:v", "1", "-q:v", "3", p], timeout=60)
            if os.path.exists(p):
                outs.append(p)
        except Exception:
            pass
    return outs


def analyze_video(mp4_path):
    frames = extract_frames(mp4_path, 3)
    if not frames:
        return ""
    try:
        return llm_vision(
            "这是同一条短视频的三帧画面。用中文具体描述：场景、主体、光线、动作、氛围。"
            "不要评价，不要猜地点，80字以内。", frames, max_tokens=180)
    finally:
        for p in frames:
            try:
                os.remove(p)
            except Exception:
                pass


# ---------------- 开放许可图库 --------------
_ALLOWED_LICENSES = ("cc0", "public domain", "pd", "cc by", "cc-by", "attribution")


def _license_ok(lic):
    s = (lic or "").lower()
    return any(k in s for k in _ALLOWED_LICENSES)


def _strip_html(s):
    return re.sub(r"<[^>]+>", "", s or "").strip()


def search_wikimedia(kind, query, limit=8):
    """kind=image/video；只返回 CC0/PD/CC BY/CC BY-SA 素材。"""
    filetype = "bitmap" if kind == "image" else "video"
    q = "%s filetype:%s" % (query, filetype)
    params = {
        "action": "query", "format": "json", "generator": "search",
        "gsrsearch": q, "gsrnamespace": "6", "gsrlimit": str(limit),
        "prop": "imageinfo", "iiprop": "url|size|mime|extmetadata",
        "iiurlwidth": "1600",
    }
    url = "https://commons.wikimedia.org/w/api.php?" + urllib.parse.urlencode(params)
    try:
        data, _, _ = fetch(url, max_bytes=3 * 1024 * 1024, timeout=30,
                           content_prefix="application/json")
        j = json.loads(data.decode("utf-8"))
    except Exception:
        return []
    pages = (j.get("query") or {}).get("pages") or {}
    out = []
    for p in pages.values():
        info = (p.get("imageinfo") or [{}])[0]
        meta = info.get("extmetadata") or {}
        lic = _strip_html((meta.get("LicenseShortName") or {}).get("value"))
        if not _license_ok(lic):
            continue
        mime = info.get("mime") or ""
        if kind == "image" and not mime.startswith("image/"):
            continue
        if kind == "video" and not mime.startswith("video/"):
            continue
        if kind == "video":
            size = int(info.get("size") or 0)
            if size and size > MAX_VIDEO_BYTES:
                continue
        out.append({
            "kind": kind,
            "url": info.get("url") or "",
            "thumb": info.get("thumburl") or "",
            "title": p.get("title") or "",
            "description": _strip_html((meta.get("ImageDescription") or {}).get("value")),
            "artist": _strip_html((meta.get("Artist") or {}).get("value")),
            "license": lic,
            "page": "https://commons.wikimedia.org/wiki/" + urllib.parse.quote(
                (p.get("title") or "").replace(" ", "_")),
            "mime": mime,
            "width": int(info.get("width") or 0),
            "height": int(info.get("height") or 0),
            "duration": float(info.get("duration") or 0),
            "size": int(info.get("size") or 0),
        })
    if kind == "video":
        out.sort(key=lambda x: ((x.get("duration") or 0) <= 0 or
                                (x.get("duration") or 0) > MAX_VIDEO_SECONDS,
                                x.get("duration") or 999))
    else:
        out.sort(key=lambda x: (x.get("width") or 0) * (x.get("height") or 0), reverse=True)
    return out


def search_openverse(query, limit=8):
    params = {"q": query, "page_size": str(limit),
              "license": "cc0,pdm,by,by-sa"}
    url = "https://api.openverse.org/v1/images/?" + urllib.parse.urlencode(params)
    try:
        data, _, _ = fetch(url, max_bytes=3 * 1024 * 1024, timeout=30,
                           content_prefix="application/json")
        j = json.loads(data.decode("utf-8"))
    except Exception:
        return []
    out = []
    for r in (j.get("results") or []):
        lic = (r.get("license") or "").upper()
        if lic not in ("CC0", "PDM", "BY", "BY-SA"):
            continue
        out.append({
            "kind": "image", "url": r.get("url") or "",
            "thumb": r.get("thumbnail") or "",
            "title": r.get("title") or "", "description": "",
            "artist": r.get("creator") or "", "license": lic,
            "page": r.get("foreign_landing_url") or "",
            "mime": "image/*", "width": int(r.get("width") or 0),
            "height": int(r.get("height") or 0), "duration": 0, "size": 0,
        })
    return out


def credit_line(item):
    artist = (item.get("artist") or "").strip()[:40]
    lic = (item.get("license") or "").strip()[:30]
    if artist and lic:
        return "素材：%s / %s" % (artist, lic)
    if lic:
        return "素材：%s" % lic
    return ""
