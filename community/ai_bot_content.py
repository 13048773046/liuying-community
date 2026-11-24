# -*- coding: utf-8 -*-
"""流小萤 · 自动内容生产与社区互动。

内容来源只取开放许可图库、GitHub 官方发布、F-Droid 和 App Store 公开页面；发布物全部进管理员审核。
模型只负责理解与写作，不负责决定权限。
"""
import html as html_lib
import json
import os
import random
import re
import time
import urllib.parse
import urllib.request
import uuid

from PIL import Image

import ai_bot_core as CORE
import ai_bot_media as MEDIA
import ai_bot_sandbox as SANDBOX

TOPIC_QUERIES = {
    "雨后的街道": "rainy street reflections",
    "城市夜色": "city skyline night",
    "山间清晨": "mountain morning mist",
    "海边的风": "ocean waves coast",
    "咖啡与书": "coffee book window",
    "午睡的猫": "cat sleeping sunlight",
    "森林小路": "forest path sunlight",
    "旧车站": "old train station",
    "夏夜的灯": "summer night lights",
    "窗边的光": "window sunlight room",
    "云层之上": "clouds above sky",
    "街头烟火": "street food night market",
    "湖面倒影": "lake reflection mountains",
    "黄昏公路": "road sunset",
    "安静的角落": "quiet library corner",
}

GH_HEADERS = {"Accept": "application/vnd.github+json", "User-Agent": MEDIA.UA}


# ---------------- 主题 ----------------
def _query_for_topic(topic):
    q = TOPIC_QUERIES.get(topic)
    if q:
        return q
    out = MEDIA.llm_text(
        "你是社区内容策划。输出 JSON，不要解释。",
        "主题：%s\n请给一个适合在 Wikimedia Commons 检索的英文关键词，并给一个中文配文角度。"
        "格式：{\"query\":\"...\",\"angle\":\"...\"}" % topic, max_tokens=200)
    obj = MEDIA.json_obj(out) or {}
    return str(obj.get("query") or topic).strip()[:80]


def choose_topic():
    p = CORE.get_policy()
    topics = [str(x).strip() for x in (p.get("topics") or []) if str(x).strip()]
    if not topics:
        topics = list(TOPIC_QUERIES.keys())
    recent = CORE.state_get("recent_topics", []) or []
    pool = [t for t in topics if t not in recent[-6:]] or topics
    topic = random.choice(pool)
    query = _query_for_topic(topic)
    recent = (recent + [topic])[-10:]
    CORE.state_set("recent_topics", recent)
    return topic, query or topic


# ---------------- 图片内容 ----------------
def _caption(kind, topic, descriptions, credit):
    desc_text = "\n".join("- " + d for d in descriptions if d)
    prompt = (
        "写一条流萤社区帖子。要求：\n"
        "1. 80-140 个中文字符，第一人称，像真实的人在分享，不要营销腔；\n"
        "2. 必须写到画面里的具体细节（光线、动作、颜色、天气），不要空泛抒情；\n"
        "3. 结尾自然带 1 个 #话题#；\n"
        "4. 不要编造地点、人物身份、品牌；\n"
        "5. 不要 emoji 堆砌，不用“宝子”“家人们”。\n"
        "主题：%s\n%s\n画面描述：\n%s" %
        (topic, "这是短视频" if kind == "video" else "这是配图帖", desc_text))
    text = MEDIA.llm_text("你是流萤社区里会写生活记录的创作者。", prompt,
                          max_tokens=500, temperature=0.6).strip()
    if not text:
        text = "把今天看到的一点点光收进相册。%s #%s#" % (
            (descriptions[0][:60] if descriptions else ""), topic)
    text = text.replace("```", "").strip()
    if credit and credit not in text:
        text = text.rstrip() + "\n" + credit
    return text[:1900]


def generate_post(topic_override=None, content_override=None):
    p = CORE.get_policy()
    if not p.get("enabled") or not p.get("auto_publish"):
        return {"ok": False, "reason": "auto_publish disabled"}
    if CORE.count_today(["post.pending", "post.published"]) >= int(p.get("max_posts_per_day") or 4):
        return {"ok": False, "reason": "daily post cap"}
    if topic_override:
        topic = str(topic_override).strip()[:40]
        query = _query_for_topic(topic)
    else:
        topic, query = choose_topic()
    candidates = MEDIA.search_wikimedia("image", query, 8) + MEDIA.search_openverse(query, 8)
    saved, descriptions, credits = [], [], []
    for item in candidates[:10]:
        if len(saved) >= 3:
            break
        url = item.get("thumb") or item.get("url")
        if not url:
            continue
        try:
            data = MEDIA.download_image(url)
            name, media = MEDIA.save_image(data)
            local = os.path.join(MEDIA.FILES_DIR, name)
            desc = MEDIA.llm_vision(
                "用中文具体描述这张图：主体、场景、光线、颜色、氛围。不要评价，50字以内。",
                [local], max_tokens=120)
            saved.append(media)
            descriptions.append(desc or item.get("description") or item.get("title") or "")
            cr = MEDIA.credit_line(item)
            if cr and cr not in credits:
                credits.append(cr)
        except Exception:
            continue
    if len(saved) < 2:
        CORE.action_log("post.auto", "", "素材不足：%s" % query, "skipped",
                        "可用图片少于 2 张")
        return {"ok": False, "reason": "not enough usable images"}
    credit = "；".join(credits[:2])
    if content_override and str(content_override).strip():
        content = str(content_override).strip()[:1900]
        if credit and credit not in content:
            content = content.rstrip() + "\n" + credit
    else:
        content = _caption("image", topic, descriptions, credit)
    pid = CORE.insert_post("text", content, images=saved, topics=[topic], source="auto")
    p = CORE.get_policy()
    approved = bool(p.get("auto_publish"))
    CORE.action_log("post.auto", pid, "自动图片帖：%s" % topic,
                    "done" if approved else "pending_review",
                    "自动发布，待抽查" if approved else "已进入管理员审核",
                    dedupe_key="auto:post:%s" % pid)
    return {"ok": True, "postId": pid, "topic": topic, "images": saved}


# ---------------- 视频内容 ----------------
def generate_video(topic_override=None, content_override=None):
    p = CORE.get_policy()
    if not p.get("enabled") or not p.get("auto_publish"):
        return {"ok": False, "reason": "auto_publish disabled"}
    if CORE.count_today(["video.pending", "video.published"]) >= int(p.get("max_videos_per_day") or 2):
        return {"ok": False, "reason": "daily video cap"}
    if topic_override:
        topic = str(topic_override).strip()[:40]
        query = _query_for_topic(topic)
    else:
        topic, query = choose_topic()
    queries = [query]
    words = query.split()
    if len(words) >= 2:
        queries.append(" ".join(words[:2]))
    if words:
        queries.append(words[0])
    queries.append("nature timelapse")
    candidates = []
    seen_urls = set()
    for q in queries:
        try:
            for item in MEDIA.search_wikimedia("video", q, 8):
                u = item.get("url")
                if u and u not in seen_urls:
                    seen_urls.add(u)
                    candidates.append(item)
        except Exception:
            continue
        if len(candidates) >= 16:
            break
    for item in candidates[:16]:
        url = item.get("url")
        if not url:
            continue
        try:
            vid, cover, dur, mp4 = MEDIA.download_video(url)
            desc = MEDIA.analyze_video(mp4)
            credit = MEDIA.credit_line(item)
            if content_override and str(content_override).strip():
                content = str(content_override).strip()[:1900]
                if credit and credit not in content:
                    content = content.rstrip() + "\n" + credit
            else:
                content = _caption("video", topic, [desc or item.get("description") or item.get("title") or ""],
                                   credit)
            CORE.insert_video(mp4, cover, dur)
            pid = CORE.insert_post("video", content, video=vid, cover=cover,
                                   duration=dur, topics=[topic], source="auto")
            CORE.action_log("video.auto", pid, "自动视频：%s" % topic,
                            "done" if p.get("auto_publish") else "pending_review",
                            "自动发布，待抽查" if p.get("auto_publish") else "已进入管理员审核",
                            dedupe_key="auto:video:%s" % pid)
            return {"ok": True, "postId": pid, "videoId": vid, "topic": topic,
                    "duration": dur}
        except Exception:
            continue
    CORE.action_log("video.auto", "", "素材不足：%s" % query, "skipped",
                    "没有可用短视频")
    return {"ok": False, "reason": "no usable video"}


# ---------------- 应用内容 ----------------
def _gh(path, params=None, max_bytes=6 * 1024 * 1024):
    url = "https://api.github.com" + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    # 优先在 AI 自己的云沙箱里访问 GitHub；沙箱忙时退回服务端受控抓取。
    data, meta = SANDBOX.fetch_json(url, max_bytes=max_bytes, timeout=35)
    if isinstance(data, (dict, list)):
        return data
    req = urllib.request.Request(url, headers=GH_HEADERS)
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read(max_bytes + 1)
        if len(raw) > max_bytes:
            raise ValueError("GitHub 响应过大")
        return json.loads(raw.decode("utf-8"))


def _text_url(url, max_bytes=4 * 1024 * 1024, timeout=35):
    """读公开网页/公开 JSON：先沙箱，再服务端受控抓取。"""
    text, meta = SANDBOX.fetch_text(url, max_bytes=max_bytes, timeout=timeout)
    if text:
        return text
    data, _, _ = MEDIA.fetch(url, max_bytes=max_bytes, timeout=timeout)
    return data.decode("utf-8", "ignore")


def _raw(repo, branch, path):
    return "https://raw.githubusercontent.com/%s/%s/%s" % (
        repo, urllib.parse.quote(branch or "main"), urllib.parse.quote(path))


def _readme_images(repo, branch):
    try:
        data, _, _ = MEDIA.fetch(_raw(repo, branch, "README.md"), max_bytes=2 * 1024 * 1024,
                                 content_prefix="text/plain")
        text = data.decode("utf-8", "ignore")
    except Exception:
        return []
    out = []
    for m in re.finditer(r"!\[[^\]]*\]\((https?://[^)\s]+|[^)\s]+)\)", text):
        out.append(m.group(1))
    for m in re.finditer(r'<img[^>]+src=["\']([^"\']+)["\']', text, re.I):
        out.append(m.group(1))
    out = [urllib.parse.urljoin(_raw(repo, branch, "README.md"), u) for u in out]
    bad = ("shields.io", "badgen", "travis", "codecov", "coveralls", "github.com/", "svg")
    return [u for u in out if not any(b in u.lower() for b in bad)][:10]


def _fastlane_images(repo, branch):
    out = []
    for path in ("fastlane/metadata/android/en-US/images/phoneScreenshots",
                 "fastlane/metadata/android/en-US/images"):
        try:
            items = _gh("/repos/%s/contents/%s" % (repo, path))
            if not isinstance(items, list):
                continue
            for it in items:
                if it.get("type") == "file" and re.search(r"\.(png|jpg|jpeg|webp)$", it.get("name", ""), re.I):
                    out.append(it.get("download_url") or "")
        except Exception:
            pass
    return [u for u in out if u][:8]


def _package_from_gradle(repo, branch):
    for path in ("app/build.gradle", "app/build.gradle.kts", "build.gradle"):
        try:
            data, _, _ = MEDIA.fetch(_raw(repo, branch, path), max_bytes=2 * 1024 * 1024,
                                     content_prefix="text/plain")
            text = data.decode("utf-8", "ignore")
            m = re.search(r"applicationId\s*[=:]\s*[\"']([A-Za-z0-9._-]{2,128})[\"']", text)
            if m:
                return m.group(1)
        except Exception:
            pass
    return ""


def _app_icon(repo, branch):
    paths = ("fastlane/metadata/android/en-US/images/icon.png", "icon.png",
             "logo.png", "assets/icon.png", "app.ico", "assets/icon.ico",
             "app/src/main/res/mipmap-xxxhdpi/ic_launcher.png")
    for path in paths:
        try:
            data, meta = SANDBOX.fetch_bytes(_raw(repo, branch, path),
                                             max_bytes=4 * 1024 * 1024, timeout=40)
            if not data:
                data, _, _ = MEDIA.fetch(_raw(repo, branch, path), max_bytes=4 * 1024 * 1024)
            im = Image.open(__import__("io").BytesIO(data))
            if im.width >= 64 and im.height >= 64:
                return MEDIA.save_image(MEDIA.normalize_image(data, square=True), square=False)[1]
        except Exception:
            pass
    return ""


def _category_for(repo_data):
    topics = " ".join(repo_data.get("topics") or []).lower()
    desc = (repo_data.get("description") or "").lower()
    if any(k in topics + desc for k in ("game", "unity", "godot")):
        return "appcat_game", "appcat_game_casual"
    if any(k in topics + desc for k in ("music", "audio", "player", "video", "media")):
        return "appcat_media", "appcat_media_player"
    if any(k in topics + desc for k in ("photo", "camera", "image", "gallery")):
        return "appcat_photo", "appcat_photo_gallery"
    if any(k in topics + desc for k in ("note", "todo", "calendar", "productivity", "task")):
        return "appcat_efficiency", "appcat_efficiency_todo"
    if any(k in topics + desc for k in ("browser", "file", "download", "security", "system")):
        return "appcat_tools", "appcat_tools_system"
    if any(k in topics + desc for k in ("learn", "study", "read", "book", "language")):
        return "appcat_study", "appcat_study_read"
    if any(k in topics + desc for k in ("chat", "social", "mail", "messaging")):
        return "appcat_social", "appcat_social_chat"
    return "appcat_other", "appcat_other_tool"


def _choose_release_asset(assets):
    for a in assets:
        name = (a.get("name") or "").lower()
        if name.endswith(".apk"):
            return a, "android", "apk"
    for a in assets:
        name = (a.get("name") or "").lower()
        if name.endswith(".exe"):
            return a, "windows", "exe"
    for a in assets:
        name = (a.get("name") or "").lower()
        if name.endswith(".msi"):
            return a, "windows", "msi"
    return None, "", ""


def _appstore_category(genres):
    text = " ".join(genres or []).lower()
    if "游戏" in text or "game" in text:
        return "appcat_game", "appcat_game_casual"
    if any(k in text for k in ("摄影", "photo", "camera")):
        return "appcat_photo", "appcat_photo_gallery"
    if any(k in text for k in ("音乐", "music", "audio")):
        return "appcat_media", "appcat_media_music"
    if any(k in text for k in ("视频", "video", "影视")):
        return "appcat_media", "appcat_media_video"
    if any(k in text for k in ("效率", "productivity", "工具", "utility")):
        return "appcat_efficiency", "appcat_efficiency_todo"
    if any(k in text for k in ("教育", "education", "阅读", "books")):
        return "appcat_study", "appcat_study_read"
    if any(k in text for k in ("社交", "social", "通讯")):
        return "appcat_social", "appcat_social_chat"
    if any(k in text for k in ("健康", "health", "健身", "fitness")):
        return "appcat_life", "appcat_life_health"
    if any(k in text for k in ("旅行", "travel", "导航")):
        return "appcat_life", "appcat_life_travel"
    if any(k in text for k in ("财务", "finance", "购物", "shopping")):
        return "appcat_life", "appcat_life_shop"
    if any(k in text for k in ("新闻", "news", "杂志")):
        return "appcat_study", "appcat_study_read"
    return "appcat_other", "appcat_other_tool"


def _save_remote_image(url, square=False, max_side=1200, max_bytes=10 * 1024 * 1024):
    """图片优先从沙箱取；取不到再走服务端受控下载。"""
    data = None
    try:
        data, _ = SANDBOX.fetch_bytes(url, max_bytes=max_bytes, timeout=50)
    except Exception:
        data = None
    if not data:
        data, _, _ = MEDIA.fetch(url, max_bytes=max_bytes, timeout=45)
    im = Image.open(__import__("io").BytesIO(data))
    if im.width < 64 or im.height < 64:
        raise ValueError("图片尺寸过小")
    return MEDIA.save_image(MEDIA.normalize_image(data, max_side=max_side, square=square))[1]


def _generate_appstore():
    """App Store 公开条目：只收录有官方商店页面的应用，不碰破解/付费绕过。"""
    terms = ["植物识别", "习惯打卡", "白噪音", "极简记账", "睡眠", "跑步",
             "笔记", "浏览器", "壁纸", "扫描", "词典", "倒数日", "喝水提醒"]
    term = random.choice(terms)
    url = "https://itunes.apple.com/search?" + urllib.parse.urlencode({
        "term": term, "country": "cn", "entity": "software", "limit": "40"})
    data, meta = SANDBOX.fetch_json(url, max_bytes=3 * 1024 * 1024, timeout=35)
    if not isinstance(data, dict) or not data.get("results"):
        CORE.action_log("app.auto", "", "App Store 检索无结果", "skipped",
                        str(meta)[:180])
        return None
    items = list(data.get("results") or [])
    random.shuffle(items)
    for item in items:
        bundle = str(item.get("bundleId") or "").strip()
        store_url = str(item.get("trackViewUrl") or "").strip()
        name = str(item.get("trackName") or "").strip()
        icon_url = str(item.get("artworkUrl512") or item.get("artworkUrl100") or "").strip()
        shots = [str(x) for x in (item.get("screenshotUrls") or []) if str(x).strip()]
        if not (bundle and store_url and name and icon_url) or len(shots) < 3:
            continue
        if not re.match(r"^[A-Za-z0-9._-]{2,128}$", bundle):
            continue
        try:
            c = CORE.db()
            if c.execute("SELECT 1 FROM community_apps WHERE platform='ios' AND package_name=?",
                         (bundle,)).fetchone():
                c.close()
                continue
            c.close()
        except Exception:
            pass
        try:
            icon = _save_remote_image(icon_url, square=True, max_side=512)
            screenshots = []
            for u in shots[:6]:
                try:
                    screenshots.append(_save_remote_image(u, max_side=1200))
                except Exception:
                    continue
            if len(screenshots) < 3:
                continue
        except Exception:
            continue
        cat, sub = _appstore_category(item.get("genres") or [])
        raw_desc = re.sub(r"\s+", " ", str(item.get("description") or "")).strip()[:1800]
        out = MEDIA.llm_text(
            "你是应用市场编辑。只根据给定信息写，不编造功能。输出 JSON。",
            "应用名：%s\nApp Store 简介：%s\n请写中文介绍（80-160字，具体说明能做什么）"
            "和一句分享感言（20-40字）。格式：{\"description\":\"...\",\"shareReason\":\"...\"}" %
            (name, raw_desc), max_tokens=500, temperature=0.4)
        obj = MEDIA.json_obj(out) or {}
        desc = str(obj.get("description") or "").strip()
        share = str(obj.get("shareReason") or "").strip()
        if len(desc) < 20:
            desc = ("「%s」是一款来自 App Store 的应用，%s。具体功能以商店页面说明为准。"
                    % (name, raw_desc[:120] or "可直接前往官方页面查看"))[:3000]
        if len(share) < 10:
            share = "界面清爽，适合需要这类工具的人试试。"
        body = {
            "name": name[:40], "icon": icon, "packageType": "store", "platform": "ios",
            "packageName": bundle, "categoryId": cat, "subcategoryId": sub,
            "description": desc[:3000], "shareReason": share[:500],
            "downloadUrl": store_url, "versionName": str(item.get("version") or "latest")[:32],
            "osVersion": str(item.get("minimumOsVersion") or "")[:30],
            "screenshots": screenshots[:6],
        }
        from app_market import service
        c = CORE.db()
        try:
            res, err = service.create_app(c, CORE.BOT_ID, body)
        finally:
            c.close()
        if err:
            CORE.action_log("app.auto", bundle, "App Store 投稿失败：%s" % err, "skipped", err[:200])
            continue
        CORE.action_log("app.pending", res.get("id", ""), "自动应用(App Store)：%s" % name,
                       "pending_review", "已进入管理员审核；来源：%s" % (meta or {}).get("source", "direct"),
                       dedupe_key="auto:app:%s" % res.get("id", ""))
        return {"ok": True, "appId": res.get("id"), "name": body["name"],
                "platform": "ios", "packageName": bundle, "source": "appstore"}
    CORE.action_log("app.auto", "", "App Store 没有完整候选", "skipped",
                    "缺少图标/截图/商店页")
    return None


def _generate_github(app_name=None, repo_override=None):
    try:
        if repo_override:
            full = str(repo_override).strip()
            if "github.com/" in full:
                full = full.split("github.com/", 1)[1].strip("/")
            repo = _gh("/repos/%s" % full)
            items = [repo]
        elif app_name:
            data = _gh("/search/repositories", {"q": "%s in:name" % app_name,
                                               "sort": "stars", "order": "desc",
                                               "per_page": "8"})
            items = data.get("items") or []
        else:
            platform_pref = random.choice(("android", "windows"))
            query = ("topic:android stars:>300 pushed:>2025-01-01" if platform_pref == "android"
                     else "topic:windows stars:>200 pushed:>2025-01-01")
            data = _gh("/search/repositories", {"q": query, "sort": "stars",
                                               "order": "desc", "per_page": "12"})
            items = data.get("items") or []
    except Exception as e:
        CORE.action_log("app.auto", "", "GitHub 检索失败", "failed", str(e)[:200])
        return None
    for repo in items:
        full = repo.get("full_name") or ""
        if not full:
            continue
        branch = repo.get("default_branch") or "main"
        try:
            rel = _gh("/repos/%s/releases/latest" % full)
        except Exception:
            continue
        asset, platform, ptype = _choose_release_asset(rel.get("assets") or [])
        if not asset:
            continue
        images = _fastlane_images(full, branch) or _readme_images(full, branch)
        images = [u for u in images if u][:6]
        if len(images) < 3:
            continue
        icon = _app_icon(full, branch)
        if not icon:
            continue
        pkg = ""
        if ptype == "apk":
            # 只接受能从源码里读到的真实 applicationId；读不到就跳过，不伪造包名。
            pkg = _package_from_gradle(full, branch)
            if not pkg:
                continue
        else:
            pkg = re.sub(r"[^A-Za-z0-9._-]", "-", full.split("/")[-1])[:60]
        try:
            c = CORE.db()
            dup = c.execute("SELECT 1 FROM community_apps WHERE platform=? AND package_name=?",
                            (platform, pkg)).fetchone()
            c.close()
            if dup:
                continue
        except Exception:
            pass
        screenshots = []
        for u in images:
            try:
                data_img = MEDIA.download_image(u, max_side=1200)
                name, media = MEDIA.save_image(data_img)
                screenshots.append(media)
            except Exception:
                continue
        if len(screenshots) < 3:
            continue
        cat, sub = _category_for(repo)
        repo_desc = (repo.get("description") or "").strip()
        out = MEDIA.llm_text(
            "你是应用市场编辑。只根据给定信息写，不编造功能。输出 JSON。",
            "应用名：%s\n平台：%s\n原始简介：%s\n请写中文介绍（80-160字，具体说明能做什么）和一句分享感言（20-40字）。"
            "格式：{\"description\":\"...\",\"shareReason\":\"...\"}" %
            (full.split("/")[-1], platform, repo_desc),
            max_tokens=500, temperature=0.4)
        obj = MEDIA.json_obj(out) or {}
        desc = str(obj.get("description") or "").strip()
        share = str(obj.get("shareReason") or "").strip()
        if len(desc) < 20:
            desc = (repo_desc[:180] or "开源应用") + "，来自 GitHub 的开源项目，支持 %s。" % platform
        if len(share) < 10:
            share = "开源、轻量，适合需要同类工具的人试试。"
        version = re.sub(r"[^A-Za-z0-9._-]", "", (rel.get("tag_name") or rel.get("name") or "latest").lstrip("v"))[:32]
        body = {
            "name": full.split("/")[-1][:40], "icon": icon,
            "packageType": ptype, "platform": platform, "packageName": pkg,
            "categoryId": cat, "subcategoryId": sub,
            "description": desc[:3000], "shareReason": share[:500],
            "downloadUrl": asset.get("browser_download_url") or "",
            "versionName": version, "osVersion": "",
            "screenshots": screenshots,
        }
        from app_market import service
        c = CORE.db()
        try:
            res, err = service.create_app(c, CORE.BOT_ID, body)
        finally:
            c.close()
        if err:
            CORE.action_log("app.auto", full, "应用投稿失败：%s" % err, "skipped", err[:200])
            continue
        CORE.action_log("app.pending", res.get("id", ""), "自动应用(GitHub)：%s" % full,
                       "pending_review", "已进入管理员审核；来源：GitHub 官方发布",
                       dedupe_key="auto:app:%s" % res.get("id", ""))
        return {"ok": True, "appId": res.get("id"), "name": body["name"],
                "platform": platform, "packageName": pkg, "source": "github"}
    CORE.action_log("app.auto", "", "GitHub 没有完整候选", "skipped",
                    "安装包/图标/截图不完整")
    return None


def generate_app(app_name=None, repo_override=None):
    p = CORE.get_policy()
    if not p.get("enabled") or not p.get("auto_publish"):
        return {"ok": False, "reason": "auto_publish disabled"}
    if CORE.count_today(["app.pending"]) >= int(p.get("max_apps_per_day") or 1):
        return {"ok": False, "reason": "daily app cap"}
    if not repo_override and not app_name:
        # AI 自己挑来源和顺序：App Store / F-Droid / GitHub 官方发布资产。
        try:
            st = SANDBOX.status()
            if st.get("ok") and int(st.get("running") or 0) < int(st.get("max") or 0):
                note = "沙箱可用，将在沙箱内联网检索"
            elif st.get("ok"):
                note = "沙箱已满，转服务端受控抓取"
            else:
                note = "沙箱离线，转服务端受控抓取"
            CORE.action_log("app.discover", "", "开始找应用：" + note, "done",
                            "沙箱 %s/%s" % (st.get("running", "?"), st.get("max", "?")))
        except Exception as e:
            CORE.action_log("app.discover", "", "开始找应用", "done", str(e)[:120])
        sources = [("appstore", _generate_appstore), ("fdroid", _generate_fdroid),
                   ("github", _generate_github)]
        random.shuffle(sources)
        last_reason = "no complete app candidate"
        for name, fn in sources:
            try:
                r = fn()
                if r and r.get("ok"):
                    return r
            except Exception as e:
                CORE.action_log("app.auto", name, "应用来源失败", "skipped", str(e)[:200])
        CORE.action_log("app.auto", "", "没有找到完整应用候选", "skipped", last_reason)
        return {"ok": False, "reason": last_reason}
    r = _generate_github(app_name=app_name, repo_override=repo_override)
    return r or {"ok": False, "reason": "no complete app candidate"}


# ---------------- F-Droid 应用源 ----------------
FDROID_HOME = "https://f-droid.org/en/packages/"
FDROID_API = "https://f-droid.org/api/v1/packages/%s"


def _fd_text(raw):
    raw = re.sub(r"<br\s*/?>", "\n", raw or "", flags=re.I)
    raw = re.sub(r"<[^>]+>", "", raw)
    return re.sub(r"\s+", " ", html_lib.unescape(raw)).strip()


def _fd_packages():
    html = _text_url(FDROID_HOME, max_bytes=4 * 1024 * 1024)
    pkgs = re.findall(r'href="/[a-z]{2,5}/packages/([A-Za-z0-9_.-]+)/"', html)
    out = []
    for p in pkgs:
        if p not in out:
            out.append(p)
    return out


def _fd_meta(pkg):
    page = "https://f-droid.org/en/packages/%s/" % urllib.parse.quote(pkg)
    html = _text_url(page, max_bytes=4 * 1024 * 1024)
    name = _fd_text((re.search(r'class="package-name">\s*([^<]+)', html) or [None, ""])[1])
    summary = _fd_text((re.search(r'class="package-summary">\s*([^<]+)', html) or [None, ""])[1])
    m = re.search(r'class="package-description"[^>]*>(.*?)(?:<div class="package-links"|<div class="package-versions"|</article>)', html, re.S)
    desc = _fd_text(m.group(1) if m else summary)[:2600]
    icon_m = re.search(r'<meta property="og:image" content="([^"]+)"', html)
    icon_url = icon_m.group(1) if icon_m else ""
    shots = []
    for u in re.findall(r'https://f-droid\.org/repo/[^"\']+/phoneScreenshots/[^"\']+\.(?:png|jpg|webp)', html):
        if u not in shots:
            shots.append(u)
    api = json.loads(_text_url(FDROID_API % urllib.parse.quote(pkg), max_bytes=1024 * 1024))
    code = str(api.get("suggestedVersionCode") or "").strip()
    ver = str(api.get("suggestedVersionName") or "").strip()
    if not code and api.get("packages"):
        code = str(api["packages"][0].get("versionCode") or "").strip()
        ver = ver or str(api["packages"][0].get("versionName") or "").strip()
    vm = re.search(r'id="latest".*?<b>Version\s+([^<]+)</b>\s*\(([0-9]+)\)', html, re.S)
    if vm:
        ver = ver or _fd_text(vm.group(1))
        code = code or vm.group(2)
    if not name or not code or not icon_url or len(shots) < 3:
        return None
    return {"package": pkg, "name": name[:40], "summary": summary, "description": desc,
            "icon": icon_url, "shots": shots[:6], "versionCode": code,
            "versionName": ver or "latest",
            "apk": "https://f-droid.org/repo/%s_%s.apk" % (pkg, code)}


def _fd_category(text):
    t = (text or "").lower()
    if any(k in t for k in ("plant", "garden", "watering", "houseplant")):
        return "appcat_life", "appcat_life_health"
    if any(k in t for k in ("calendar", "schedule", "reminder")):
        return "appcat_efficiency", "appcat_efficiency_calendar"
    if any(k in t for k in ("note", "notepad", "memo")):
        return "appcat_efficiency", "appcat_efficiency_note"
    if any(k in t for k in ("todo", "task", "checklist")):
        return "appcat_efficiency", "appcat_efficiency_todo"
    if any(k in t for k in ("music", "audio", "player", "podcast", "radio")):
        return "appcat_media", "appcat_media_player"
    if any(k in t for k in ("video", "movie", "stream")):
        return "appcat_media", "appcat_media_video"
    if any(k in t for k in ("photo", "camera", "gallery", "image")):
        return "appcat_photo", "appcat_photo_gallery"
    if any(k in t for k in ("chat", "messaging", "sms", "mail", "matrix")):
        return "appcat_social", "appcat_social_chat"
    if any(k in t for k in ("read", "book", "reader", "dictionary", "language")):
        return "appcat_study", "appcat_study_read"
    if any(k in t for k in ("game", "puzzle", "arcade", "card table", "card game")):
        return "appcat_game", "appcat_game_casual"
    if any(k in t for k in ("weather", "travel", "health", "fitness")):
        return "appcat_life", "appcat_life_health"
    return "appcat_tools", "appcat_tools_system"


def _fd_icon(url):
    data, _, _ = MEDIA.fetch(url, max_bytes=6 * 1024 * 1024)
    return MEDIA.save_image(data, square=True)[1]


def _fd_app(pkg):
    c = CORE.db()
    try:
        if c.execute("SELECT 1 FROM community_apps WHERE platform='android' AND package_name=?",
                     (pkg,)).fetchone():
            return None
    finally:
        c.close()
    meta = _fd_meta(pkg)
    if not meta:
        return None
    icon = _fd_icon(meta["icon"])
    shots = []
    for u in meta["shots"]:
        try:
            data = MEDIA.download_image(u, max_side=1200)
            shots.append(MEDIA.save_image(data)[1])
        except Exception:
            continue
    if len(shots) < 3:
        return None
    src = (meta["summary"] + "\n" + meta["description"])[:2600]
    out = MEDIA.llm_text(
        "你是应用市场编辑。只根据给定资料写，不编造功能。输出 JSON。",
        "应用名：%s\nF-Droid 简介：%s\nF-Droid 详情：%s\n"
        "请写中文应用介绍（80-160字，具体说明能做什么）和一句分享感言（20-40字）。"
        "格式：{\"description\":\"...\",\"shareReason\":\"...\"}" %
        (meta["name"], meta["summary"], src), max_tokens=500, temperature=0.4)
    obj = MEDIA.json_obj(out) or {}
    desc = str(obj.get("description") or "").strip()
    share = str(obj.get("shareReason") or "").strip()
    if len(desc) < 20 or not re.search(r"[\u4e00-\u9fff]", desc):
        desc = ("「%s」是一款来自 F-Droid 的开源 Android 应用，%s。"
                "安装包、图标和截图均来自 F-Droid 官方仓库，适合愿意尝试开源工具的用户。"
                % (meta["name"], meta["summary"] or "功能以应用页说明为准"))[:3000]
    if len(share) < 10:
        share = "开源、轻量，适合需要这类工具的人试试。"
    cat, sub = _fd_category(meta["summary"] + " " + meta["description"])
    body = {
        "name": meta["name"], "icon": icon, "packageType": "apk", "platform": "android",
        "packageName": meta["package"], "categoryId": cat, "subcategoryId": sub,
        "description": desc[:3000], "shareReason": share[:500],
        "downloadUrl": meta["apk"], "versionName": meta["versionName"],
        "osVersion": "", "screenshots": shots[:6],
    }
    from app_market import service
    c = CORE.db()
    try:
        res, err = service.create_app(c, CORE.BOT_ID, body)
    finally:
        c.close()
    if err:
        CORE.action_log("app.auto", meta["package"], "应用投稿失败：%s" % err,
                        "skipped", err[:200])
        return None
    CORE.action_log("app.pending", res.get("id", ""), "自动应用(F-Droid)：%s" % meta["package"],
                   "pending_review", "已进入管理员审核；来源：F-Droid",
                   dedupe_key="auto:app:%s" % res.get("id", ""))
    return {"ok": True, "appId": res.get("id"), "name": meta["name"],
            "platform": "android", "packageName": meta["package"]}


def _generate_fdroid():
    try:
        pkgs = _fd_packages()
    except Exception as e:
        CORE.action_log("app.auto", "", "F-Droid 列表失败", "failed", str(e)[:200])
        return None
    c = CORE.db()
    try:
        existing = {r[0] for r in c.execute(
            "SELECT package_name FROM community_apps WHERE platform='android'")}
    finally:
        c.close()
    todo = [p for p in pkgs if p not in existing]
    random.shuffle(todo)
    for pkg in todo[:12]:
        try:
            r = _fd_app(pkg)
            if r:
                return r
        except Exception as e:
            CORE.action_log("app.auto", pkg, "F-Droid 候选失败", "skipped", str(e)[:200])
            continue
    CORE.action_log("app.auto", "", "F-Droid 没有完整候选", "skipped",
                    "图标、截图或 APK 不完整")
    return None


# ---------------- 自动互动 ----------------
CONF_COMMENT = (
    "你看过这条社区内容。写一条真实、具体的中文评论，10-40 字。"
    "必须提到你看到的画面或观点细节，不要泛泛夸“好棒”“支持”。"
    "如果信息不足以下判断，只输出 SKIP。不要营销，不要 emoji。"
)


def _post_media_desc(post):
    paths = CORE.post_media_paths(post)
    frames = []
    for p in paths:
        if os.path.basename(p).startswith("_") or ".frame" in p:
            frames.append(p)
    try:
        if paths:
            return MEDIA.llm_vision(
                "用中文具体描述这些画面：主体、场景、光线、动作、氛围。不要评价，80字以内。",
                paths, max_tokens=200)
    finally:
        for p in frames:
            try:
                os.remove(p)
            except Exception:
                pass


def _auto_comment_for_post(post):
    desc = _post_media_desc(post)
    text = post.get("content") or ""
    out = MEDIA.llm_text(
        "你正在浏览流萤社区，只输出评论正文或 SKIP。",
        CONF_COMMENT + "\n\n帖子正文：%s\n画面：%s" % (text[:300], desc[:300]),
        max_tokens=200, temperature=0.5).strip()
    if not out or "SKIP" in out.upper():
        return ""
    return out.strip().strip("“”\"")[:160]


def _auto_comment_for_app(app):
    out = MEDIA.llm_text(
        "你正在浏览流萤社区应用市场，只输出评论正文或 SKIP。",
        "根据应用名和介绍写一条 10-40 字中文评论，必须提到具体功能，不要编造没有的功能。"
        "信息不足就输出 SKIP。\n应用：%s\n介绍：%s" %
        (app.get("name"), (app.get("description") or "")[:300]),
        max_tokens=180, temperature=0.4).strip()
    if not out or "SKIP" in out.upper():
        return ""
    return out.strip().strip("“”\"")[:200]


def engage():
    p = CORE.get_policy()
    if not p.get("enabled") or not p.get("auto_engage"):
        return {"ok": False, "reason": "auto_engage disabled"}
    posts = CORE.recent_posts(30, days=4)
    likes = 0
    comments = 0
    favs = 0
    like_cap = max(0, int(p.get("max_likes_per_day") or 30) - CORE.count_today(["post.like"]))
    comment_cap = max(0, int(p.get("max_comments_per_day") or 8) - CORE.count_today(["post.comment"]))
    fav_cap = max(0, int(p.get("max_favs_per_day") or 15) - CORE.count_today(["post.fav"]))
    # 视频优先，保证短视频也有真实互动
    ordered = sorted(posts, key=lambda x: 0 if x.get("type") == "video" else 1)
    for post in ordered:
        if likes >= like_cap:
            break
        if post.get("id") and CORE.like_post(post["id"], source="auto") == "已点赞":
            likes += 1
        if likes >= min(like_cap, 6):
            break
    for post in ordered:
        if comments >= comment_cap or comments >= 2:
            break
        content = _auto_comment_for_post(post)
        if content and CORE.comment_post(post["id"], content, source="auto") == "已评论":
            comments += 1
    for post in ordered[:5]:
        if favs >= fav_cap or favs >= 3:
            break
        if CORE.favorite_post(post["id"], source="auto") == "已收藏":
            favs += 1
    # 应用收藏/评论
    apps = CORE.recent_apps(20, days=60)
    app_fav = 0
    app_comments = 0
    app_comment_cap = max(0, int(p.get("max_app_comments_per_day") or 3) - CORE.count_today(["app.comment"]))
    for app in apps[:4]:
        if app_fav >= 2:
            break
        if CORE.like_app(app["id"], source="auto") == "已收藏":
            app_fav += 1
    for app in apps[:6]:
        if app_comments >= app_comment_cap or app_comments >= 1:
            break
        content = _auto_comment_for_app(app)
        if content and CORE.comment_app(app["id"], content, source="auto") == "已评论":
            app_comments += 1
    return {"ok": True, "likes": likes, "comments": comments, "favs": favs,
            "appFavs": app_fav, "appComments": app_comments}


# ---------------- 统一入口 ----------------
def run_kind(kind):
    kind = (kind or "").strip().lower()
    try:
        if kind == "post":
            return generate_post()
        if kind == "video":
            return generate_video()
        if kind == "app":
            return generate_app()
        if kind == "engage":
            return engage()
        if kind == "followback":
            n = CORE.followback_scan()
            return {"ok": True, "followedBack": n}
        if kind == "all":
            out = {}
            for k in ("followback", "engage", "post", "video", "app"):
                out[k] = run_kind(k)
            return {"ok": True, "results": out}
        return {"ok": False, "reason": "unknown kind"}
    except Exception as e:
        CORE.action_log("worker.error", kind, "自动任务失败", "failed", str(e)[:300])
        return {"ok": False, "reason": str(e)[:300]}
