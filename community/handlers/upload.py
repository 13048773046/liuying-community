# -*- coding: utf-8 -*-
"""流萤社区 · 上传域：图片/视频上传、转码、封面（三模式）、文件访问、分享落地页。

封面三模式：auto（自动首帧）/ frame（指定帧 ffmpeg 抽帧）/ upload（用户上传图）。
转码：ffmpeg → H.264/AAC，产出 {id}.mp4（原）+ {id}_720.mp4 / {id}_480.mp4（多档）。
"""
import os
import re
import json
import time
import uuid
import subprocess
import threading
import urllib.parse

from common import (db, resolve_token, rate_limit, image_magic_ok, video_magic_ok, row_dict,
                    FILES_DIR, ATTACHMENT_MIME, MAX_ATTACHMENT_BYTES, MAX_ATTACHMENTS,
                    clean_attachment_label)
from core.settings import settings
from core.security import cors_headers, security_headers

MAX_IMAGE = 10 * 1024 * 1024        # 10MB
MAX_VIDEO = 50 * 1024 * 1024        # 50MB
MAX_DURATION = 60.0                 # 60s
ALLOWED_IMG = (".png", ".jpg", ".jpeg", ".webp", ".gif")
ALLOWED_VID = (".mp4", ".webm")


def _magic_ok_for_attachment(head, ext):
    """文档附件魔数校验：Office/压缩包不能靠后缀伪装成可执行文件。"""
    if ext == ".pdf":
        return head[:5] == b"%PDF-"
    if ext in (".docx", ".xlsx", ".pptx", ".zip"):
        return head[:4] in (b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08")
    if ext in (".doc", ".xls", ".ppt"):
        return head[:8] == b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"
    if ext == ".rar":
        return head[:4] == b"Rar!"
    if ext == ".7z":
        return head[:6] == b"7z\xbc\xaf\x27\x1c"
    if ext in (".txt", ".md", ".csv"):
        return b"\x00" not in head and b"\xff" not in head
    return False


_transcode_lock = threading.Lock()
_transcode_jobs = {}                 # videoId -> status


def _uid(c, handler):
    return resolve_token(c, handler.headers.get("Authorization", ""))


def _media_url(name):
    return "/community/api/media/" + name


# ---------------- 图片上传 ----------------
def _handle_upload_image(self, c, u, api, method):
    if api != "/upload-image":
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    if not rate_limit(self, "upload_image"):
        self._err(429, "上传过于频繁，请稍后再试")
        return True
    fields, files = self._multipart(MAX_IMAGE * 3 + 8192)
    if files is None:
        self._err(400, "上传数据无效")
        return True
    fdata = None
    fname = ""
    for k, (fn, data) in files.items():
        if data:
            fdata, fname = data, fn
            break
    if not fdata:
        self._err(400, "缺少图片文件")
        return True
    ext = os.path.splitext(fname)[1].lower()
    if ext not in ALLOWED_IMG:
        ext = ".png"
    if not image_magic_ok(fdata[:32], ext):
        self._err(400, "图片格式校验失败")
        return True
    if len(fdata) > MAX_IMAGE:
        self._err(413, "图片过大（≤10MB）")
        return True
    fname_out = "community_img_%s_%s%s" % (uid[:8], uuid.uuid4().hex[:10], ext)
    with open(os.path.join(FILES_DIR, fname_out), "wb") as f:
        f.write(fdata)
    c.commit()
    self._ok({"url": _media_url(fname_out), "name": fname_out})
    return True


# ---------------- 视频上传（含转码 + 封面三模式） ----------------
def _handle_upload_file(self, c, u, api, method):
    """通用文件上传（会员支付凭证等）：图片或 PDF，≤10MB。"""
    if api != "/upload-file":
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    if not rate_limit(self, "upload_file"):
        self._err(429, "上传过于频繁，请稍后再试")
        return True
    fields, files = self._multipart(MAX_IMAGE * 2 + 8192)
    if files is None:
        self._err(400, "上传数据无效")
        return True
    fdata, fname = None, ""
    for k, (fn, data) in files.items():
        if data:
            fdata, fname = data, fn
            break
    if not fdata:
        self._err(400, "缺少文件")
        return True
    ext = os.path.splitext(fname)[1].lower()
    if ext not in ALLOWED_IMG + (".pdf",):
        self._err(400, "只支持图片或 PDF")
        return True
    if len(fdata) > MAX_IMAGE:
        self._err(413, "文件过大（≤10MB）")
        return True
    if ext == ".pdf":
        if not fdata[:5] == b"%PDF-":
            self._err(400, "PDF 格式校验失败")
            return True
    elif not image_magic_ok(fdata[:32], ext):
        self._err(400, "图片格式校验失败")
        return True
    out = "community_file_%s_%s%s" % (uid[:8], uuid.uuid4().hex[:10], ext)
    with open(os.path.join(FILES_DIR, out), "wb") as f:
        f.write(fdata)
    c.commit()
    self._ok({"url": _media_url(out), "name": out, "size": len(fdata)})
    return True


def _handle_upload_attachment(self, c, u, api, method):
    """帖子附件：PDF / Office / 文本 / 压缩包，单文件 ≤20MB，最多 2 个。"""
    if api != "/upload-attachment":
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    if not rate_limit(self, "upload_attachment"):
        self._err(429, "上传过于频繁，请稍后再试")
        return True
    fields, files = self._multipart(MAX_ATTACHMENT_BYTES + 64 * 1024)
    if files is None:
        self._err(400, "附件上传数据无效或超过 20MB")
        return True
    fdata, fname = None, ""
    for k, (fn, data) in files.items():
        if data:
            fdata, fname = data, fn
            break
    if not fdata:
        self._err(400, "缺少附件文件")
        return True
    label = clean_attachment_label(fname)
    ext = os.path.splitext(label)[1].lower()
    if ext not in ATTACHMENT_MIME:
        self._err(400, "只支持 PDF、Office 文档、文本或压缩包")
        return True
    if len(fdata) > MAX_ATTACHMENT_BYTES:
        self._err(413, "附件过大（≤20MB）")
        return True
    if not _magic_ok_for_attachment(fdata[:64], ext):
        self._err(400, "附件格式校验失败，请检查文件是否损坏")
        return True
    out = "community_attach_%s_%s%s" % (uid[:8], uuid.uuid4().hex[:10], ext)
    with open(os.path.join(FILES_DIR, out), "wb") as f:
        f.write(fdata)
    c.commit()
    self._ok({
        "name": out,
        "label": label,
        "size": len(fdata),
        "ext": ext.lstrip("."),
        "mime": ATTACHMENT_MIME[ext],
        "url": _media_url(out),
        "maxCount": MAX_ATTACHMENTS,
        "maxBytes": MAX_ATTACHMENT_BYTES,
    })
    return True


def _handle_upload_video(self, c, u, api, method):
    if api != "/upload-video":
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    if not rate_limit(self, "upload_video"):
        self._err(429, "上传过于频繁，请稍后再试")
        return True
    fields, files = self._multipart(MAX_VIDEO + 64 * 1024)
    if files is None:
        self._err(400, "上传数据无效")
        return True
    fdata = None
    fname = ""
    for k, (fn, data) in files.items():
        if data:
            fdata, fname = data, fn
            break
    if not fdata:
        self._err(400, "缺少视频文件")
        return True
    ext = os.path.splitext(fname)[1].lower()
    if ext not in ALLOWED_VID:
        ext = ".mp4"
    if not video_magic_ok(fdata[:32]):
        self._err(400, "视频格式校验失败（仅 mp4/webm）")
        return True
    if len(fdata) > MAX_VIDEO:
        self._err(413, "视频过大（≤50MB）")
        return True
    vid = "community_video_%s_%s" % (uid[:8], uuid.uuid4().hex[:10])
    src_path = os.path.join(FILES_DIR, vid + ext)
    with open(src_path, "wb") as f:
        f.write(fdata)
    # 时长探测
    dur = _probe_duration(src_path)
    if dur and dur > MAX_DURATION:
        os.remove(src_path)
        self._err(400, "视频时长超出限制（≤60s）")
        return True
    _transcode_jobs[vid] = {"status": "processing", "done": False}
    c.execute("INSERT INTO community_videos(id,user_id,duration,status,cover,error,created,updated)"
              " VALUES(?,?,?,?,?,?,?,?)",
              (vid, uid, dur or 0, "processing", "", "", time.time(), time.time()))
    threading.Thread(target=_transcode, args=(src_path, vid, ext, dur), daemon=True).start()
    c.commit()
    self._ok({"videoId": vid, "name": vid + ext, "duration": dur or 0,
              "status": "processing"})
    return True


def _probe_duration(path):
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            capture_output=True, timeout=30)
        return float(r.stdout.decode().strip() or 0)
    except Exception:
        return 0


def _transcode(src_path, vid, ext, dur):
    """转码：统一转 H.264/AAC 主文件 + 720/480 多档 + 自动首帧封面。"""
    try:
        base = os.path.join(FILES_DIR, vid)
        main = base + ".mp4"
        # 主文件
        _run_ff(["ffmpeg", "-y", "-i", src_path, "-c:v", "libx264", "-preset", "medium",
                 "-crf", "23", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart",
                 main])
        # 720p / 480p
        for label, scale in (("_720", "1280:720"), ("_480", "854:480")):
            out = base + label + ".mp4"
            _run_ff(["ffmpeg", "-y", "-i", src_path, "-vf", "scale=%s:-2" % scale,
                     "-c:v", "libx264", "-preset", "medium", "-crf", "25",
                     "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", out])
        # 自动首帧封面
        cover = base + ".jpg"
        _run_ff(["ffmpeg", "-y", "-i", src_path, "-frames:v", "1", "-q:v", "3", cover])
        # 清理原始文件（非 mp4 时）
        if ext != ".mp4":
            try:
                os.remove(src_path)
            except Exception:
                pass
        with _transcode_lock:
            _transcode_jobs[vid] = {"status": "done", "done": True}
        _update_video_db(vid, "done", cover=cover)
    except Exception as e:
        with _transcode_lock:
            _transcode_jobs[vid] = {"status": "failed", "error": str(e)}
        _update_video_db(vid, "failed", error=str(e))
        import traceback
        traceback.print_exc()


def _update_video_db(vid, status, cover="", error=""):
    """转码完成后落库（独立连接，避免与请求线程连接冲突）。"""
    try:
        from common import db
        c = db()
        c.execute("UPDATE community_videos SET status=?, cover=?, error=?, updated=? WHERE id=?",
                  (status, cover, error, time.time(), vid))
        c.commit()
        c.close()
    except Exception:
        pass


def _run_ff(cmd):
    try:
        subprocess.run(cmd, capture_output=True, timeout=300, check=True)
        return True
    except Exception:
        return False


# ---------------- 指定帧抽封面 ----------------
def _handle_cover_frame(self, c, u, api, method):
    m = re.match(r"^/video/([\w\-]+)/cover-frame$", api)
    if not m:
        return False
    if method != "POST":
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    vid = m.group(1)
    body = self._json_body() or {}
    try:
        t = float(body.get("frameTime") or 0)
    except Exception:
        t = 0
    src = None
    for ext in (".mp4", ".webm"):
        p = os.path.join(FILES_DIR, vid + ext)
        if os.path.exists(p):
            src = p
            break
    if not src:
        # 转码产物
        for ext in (".mp4",):
            p = os.path.join(FILES_DIR, vid + ext)
            if os.path.exists(p):
                src = p
                break
    if not src:
        self._err(404, "视频不存在")
        return True
    out = os.path.join(FILES_DIR, vid + "_frame.jpg")
    _run_ff(["ffmpeg", "-y", "-ss", str(max(t, 0)), "-i", src, "-frames:v", "1",
             "-q:v", "3", out])
    if not os.path.exists(out):
        # 回退首帧
        _run_ff(["ffmpeg", "-y", "-i", src, "-frames:v", "1", "-q:v", "3", out])
    c.commit()
    self._ok({"cover": _media_url(vid + "_frame.jpg")})
    return True


# ---------------- 音乐媒体代理（头像/背景/封面/配乐） ----------------
_MUSIC_AUDIO = (".m4a", ".mp3", ".aac", ".opus", ".ogg", ".wav", ".flac")
_MUSIC_IMAGE = (".jpg", ".jpeg", ".png", ".webp", ".gif")


def _music_files_root():
    candidates = [settings.music_files_dir, "/www/wwwroot/music/data/media/files"]
    for root in candidates:
        if root and os.path.isdir(root):
            return os.path.realpath(root)
    return os.path.realpath(settings.music_files_dir)


def _safe_music_file(name):
    if not name or os.path.basename(name) != name:
        return None
    root = _music_files_root()
    real = os.path.realpath(os.path.join(root, name))
    if not real.startswith(root + os.sep):
        return None
    if not os.path.isfile(real):
        return None
    return real


def _media_headers(self, name, ctype, size=None, extra=None):
    """媒体响应统一安全头：不能因为传了 HTML 就在社区同源执行脚本。"""
    for k, v in (extra or {}).items():
        self.send_header(k, v)
    if size is not None:
        self.send_header("Content-Length", str(size))
    self.send_header("Content-Type", ctype)
    self.send_header("Accept-Ranges", "bytes")
    self.send_header("Cache-Control", "public, max-age=604800")
    origin = self.headers.get("Origin", "")
    for k, v in cors_headers(origin, settings.cors_origins).items():
        self.send_header(k, v)
    headers = security_headers(is_html=False, secure=True)
    headers.pop("Cross-Origin-Resource-Policy", None)
    headers["Cross-Origin-Resource-Policy"] = "cross-origin"
    if ctype.lower().startswith("text/html"):
        # 关键：sandbox 不带 allow-same-origin，页面无法读取社区域的
        # cookie/localStorage，即使被 XSS 也只能在唯一源里运行。
        headers["Content-Security-Policy"] = (
            "sandbox allow-scripts allow-forms allow-popups allow-modals; "
            "default-src 'none'; style-src 'unsafe-inline' https: data:; "
            "img-src 'self' data: blob: https:; font-src data: https:; "
            "script-src 'unsafe-inline' https:; connect-src https:; "
            "media-src https:; base-uri 'none'; object-src 'none'; "
            "frame-ancestors 'self'"
        )
        headers["Content-Disposition"] = "inline"
    for k, v in headers.items():
        self.send_header(k, v)


def _serve_local_file(self, real, name):
    size = os.path.getsize(real)
    ext = os.path.splitext(name)[1].lower()
    ctype = {
        ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
        ".webp": "image/webp", ".gif": "image/gif",
        ".m4a": "audio/mp4", ".mp3": "audio/mpeg", ".aac": "audio/aac",
        ".opus": "audio/opus", ".ogg": "audio/ogg", ".wav": "audio/wav",
        ".flac": "audio/flac",
    }.get(ext, "application/octet-stream")
    rng = self.headers.get("Range", "")
    start, end = 0, size - 1
    if rng and rng.startswith("bytes="):
        try:
            spec = rng[len("bytes="):].split("-", 1)
            start = int(spec[0] or 0)
            if spec[1]:
                end = min(int(spec[1]), size - 1)
        except Exception:
            start, end = 0, size - 1
        if start > end:
            self.send_response(416)
            self.send_header("Content-Range", "bytes */%d" % size)
            self.end_headers()
            return True
    with open(real, "rb") as f:
        if rng:
            f.seek(start)
            chunk = f.read(end - start + 1)
            self.send_response(206)
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        else:
            chunk = f.read()
            self.send_response(200)
    extra = {}
    if name.startswith("community_pkg_"):
        extra["Content-Disposition"] = 'attachment; filename="%s"' % name
    _media_headers(self, name, ctype, len(chunk), extra)
    self.end_headers()
    try:
        self.wfile.write(chunk)
    except Exception:
        pass
    return True


def _handle_music_media(self, c, u, api, method):
    if method != "GET":
        return False
    m = re.match(r"^/music/files/([\w\-\.]+)$", api)
    if m:
        name = m.group(1)
        if not name.lower().endswith(_MUSIC_AUDIO):
            self._err(403, "forbidden")
            return True
        real = _safe_music_file(name)
        if not real:
            self._err(404, "not found")
            return True
        return _serve_local_file(self, real, name)

    m = re.match(r"^/music/cover/([\w\-]+)(\.jpg)?$", api)
    if m:
        tid = m.group(1)
        cover = ""
        row = c.execute("SELECT cover FROM tracks WHERE id=?", (tid,)).fetchone()
        if row:
            cover = row[0] or ""
        if not cover:
            try:
                crow = c.execute("SELECT cover FROM collected_tracks WHERE id=?", (tid,)).fetchone()
                cover = (crow[0] or "") if crow else ""
            except Exception:
                cover = ""
        real = _safe_music_file(cover) if cover and not str(cover).startswith("http") else None
        if not real:
            local = _safe_music_file(tid + "_cover.jpg")
            if local:
                return _serve_local_file(self, local, tid + "_cover.jpg")
        if not real and str(cover).startswith("http"):
            self.send_response(302)
            self.send_header("Content-Length", "0")
            self.send_header("Location", str(cover))
            self.send_header("Cache-Control", "no-store")
            for k, v in cors_headers(self.headers.get("Origin", ""), settings.cors_origins).items():
                self.send_header(k, v)
            for k, v in security_headers(is_html=False, secure=True).items():
                self.send_header(k, v)
            self.end_headers()
            return True
        if not real:
            self._err(404, "no cover")
            return True
        return _serve_local_file(self, real, os.path.basename(real))

    m = re.match(r"^/music/(avatar|background)/([\w\-]+)$", api)
    if m:
        kind, uid = m.group(1), m.group(2)
        col = "avatar" if kind == "avatar" else "background_image"
        row = c.execute("SELECT " + col + " FROM users WHERE id=?", (uid,)).fetchone()
        name = (row[0] or "") if row else ""
        real = _safe_music_file(name)
        if not real and kind == "avatar":
            real = _safe_music_file(uid + "_avatar.jpg")
        if not real:
            self._err(404, "not found")
            return True
        return _serve_local_file(self, real, os.path.basename(real))
    return False


# ---------------- 视频/图片访问（白名单） ----------------
def _handle_media(self, c, u, api, method):
    m = re.match(r"^/media/([\w\-\./%\u4e00-\u9fff]+)$", api)
    if not m:
        return False
    name = urllib.parse.unquote(m.group(1))
    # 白名单：community_img_* / community_banner_* / community_video_* / *_frame.jpg / 表情包 emoji_official/*
    if not re.match(r"^(community_img_[\w\-\.]+|community_banner_[\w\-\.]+|community_pkg_[\w\-\.]+|community_ipa_[\w\-\.]+|community_attach_[\w\-\.]+|community_video_[\w\-]+(\.[\w]+|_frame\.jpg|_720\.mp4|_480\.mp4)|emoji_official/[\w\-\./]+|frames/[\w\-\./]+|af/[\w\-\./%\u4e00-\u9fff]+)$", name):
        self._err(403, "forbidden")
        return True
    # 防目录穿越：拒绝任何 . / .. 段，并用 commonpath 做完整前缀比较
    # （startswith 会把 files_probe 误认为 files 的子目录）。
    parts = [x for x in name.split("/") if x]
    if not parts or any(x in (".", "..") for x in parts):
        self._err(403, "forbidden")
        return True
    root = os.path.realpath(FILES_DIR)
    real = os.path.realpath(os.path.join(root, name))
    try:
        if os.path.commonpath([real, root]) != root:
            self._err(403, "forbidden")
            return True
    except ValueError:
        self._err(403, "forbidden")
        return True
    if not os.path.isfile(real):
        self._err(404, "not found")
        return True
    size = os.path.getsize(real)
    ctype = "application/octet-stream"
    if name.endswith((".jpg", ".jpeg")):
        ctype = "image/jpeg"
    elif name.endswith(".png"):
        ctype = "image/png"
    elif name.endswith(".webp"):
        ctype = "image/webp"
    elif name.endswith(".gif"):
        ctype = "image/gif"
    elif name.endswith(".mp4"):
        ctype = "video/mp4"
    elif name.endswith(".webm"):
        ctype = "video/webm"
    elif name.endswith(".txt") or name.endswith(".md"):
        ctype = "text/plain; charset=utf-8"
    elif name.endswith(".pdf"):
        ctype = "application/pdf"
    elif name.endswith(".html"):
        ctype = "text/html; charset=utf-8"
    elif name.endswith(".json"):
        ctype = "application/json; charset=utf-8"
    elif name.endswith(".apk"):
        ctype = "application/vnd.android.package-archive"
    elif name.endswith(".ipa"):
        ctype = "application/octet-stream"
    if name.startswith("community_attach_"):
        ctype = ATTACHMENT_MIME.get(os.path.splitext(name)[1].lower(),
                                    "application/octet-stream")
    # 206 分片
    rng = self.headers.get("Range", "")
    start, end = 0, size - 1
    if rng and rng.startswith("bytes="):
        try:
            spec = rng[len("bytes="):].split("-", 1)
            start = int(spec[0] or 0)
            if spec[1]:
                end = min(int(spec[1]), size - 1)
        except Exception:
            start, end = 0, size - 1
        if start > end:
            self.send_response(416)
            self.send_header("Content-Range", "bytes */%d" % size)
            self.end_headers()
            return True
    with open(real, "rb") as f:
        if rng:
            f.seek(start)
            chunk = f.read(end - start + 1)
            self.send_response(206)
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        else:
            chunk = f.read()
            self.send_response(200)
    extra = {}
    if name.startswith("community_pkg_"):
        extra["Content-Disposition"] = 'attachment; filename="%s"' % name
    elif name.startswith("community_attach_"):
        # 原始文件名只用于下载头，不参与磁盘路径。
        q = urllib.parse.parse_qs(u.query or "")
        label = clean_attachment_label((q.get("name") or [""])[0] or name)
        ascii_name = label.encode("ascii", "ignore").decode("ascii").strip() or "attachment"
        ascii_name = ascii_name.replace('"', "'")[:120]
        extra["Content-Disposition"] = (
            'attachment; filename="%s"; filename*=UTF-8\'\'%s'
            % (ascii_name, urllib.parse.quote(label, safe=""))
        )
    _media_headers(self, name, ctype, len(chunk), extra)
    self.end_headers()
    try:
        self.wfile.write(chunk)
    except Exception:
        pass
    return True


# ---------------- 视频状态 / 分享落地页 ----------------
def _handle_video_status(self, c, u, api, method):
    m = re.match(r"^/video/([\w\-]+)/status$", api)
    if not m:
        return False
    vid = m.group(1)
    row = c.execute("SELECT status, cover, duration FROM community_videos WHERE id=?",
                    (vid,)).fetchone()
    st = row_dict(row) if row else {"status": "unknown"}
    with _transcode_lock:
        mem = _transcode_jobs.get(vid, {})
    if not row and mem.get("status") == "done":
        st = {"status": "done"}
    c.commit()
    self._ok({"videoId": vid, "status": st.get("status", "unknown"),
              "cover": st.get("cover", ""),
              "url": _media_url(vid + ".mp4") if st.get("status") == "done" else ""})
    return True


def _handle_share_page(self, c, u, api, method):
    """GET /s/{id} → 302 到 H5 分享落地页（社区 web 目录）"""
    m = re.match(r"^/s/([\w\-]+)$", api)
    if not m:
        return False
    pid = m.group(1)
    row = c.execute("SELECT * FROM community_posts WHERE id=? AND status=1", (pid,)).fetchone()
    if not row:
        self.send_response(302)
        self.send_header("Location", "/community/share.html?notfound=1")
        self.end_headers()
        return True
    d = row_dict(row)
    if d.get("audit_status", 0) != 1 or d.get("taken_down", 0):
        self.send_response(302)
        self.send_header("Location", "/community/share.html?notfound=1")
        self.end_headers()
        return True
    self.send_response(302)
    self.send_header("Location", "/community/share.html?id=" + pid)
    self.end_headers()
    return True


def dispatch(self, c, u, api, method):
    handlers = [_handle_upload_image, _handle_upload_file, _handle_upload_attachment,
                _handle_upload_video, _handle_cover_frame,
                _handle_music_media, _handle_media, _handle_video_status, _handle_share_page]
    for h in handlers:
        if h(self, c, u, api, method):
            return True
    return False
