# -*- coding: utf-8 -*-
"""官网内容配置：一处存储、官网即时生效。

只存可运营的展示文案与素材地址，不存模板源码。
管理端改完后，官网通过 /api/site/content 拉取并局部替换。
"""
from __future__ import annotations

import copy
import json
import time

from common import db

CONFIG_KEY = "site_content"
MAX_JSON = 512 * 1024

DEFAULT_CONTENT = {
    "seo": {
        "title": "流萤社区 · 把夜晚，留给还在醒着的人",
        "description": "流萤社区，一个安静的地方。发一条没人催你的动态，听一首刚好在心里的歌，看看别人怎么度过今晚。",
        "ogTitle": "流萤社区 · 把夜晚，留给还在醒着的人",
        "ogDescription": "一个不太吵的地方。夜里也有人回应。",
        "ogImage": "https://www.dbmt999.asia/community/static/scene.jpg",
        "canonical": "https://www.dbmt999.asia/community/",
    },
    "brand": {
        "name": "流萤社区",
        "en": "LIUYING COMMUNITY",
        "slogan": "夜里也有人回应",
        "navCta": "进入夜航",
        "navCtaLink": "#now",
        "mobileFoot": "LIUYING COMMUNITY · 夜里也有人回应",
    },
    "nav": {
        "items": [
            {"label": "社区此刻", "url": "#now"},
            {"label": "角色档案", "url": "#character"},
            {"label": "夜航", "url": "#night"},
            {"label": "版块", "url": "#boards"},
            {"label": "客户端", "url": "#client"},
        ],
    },
    "hero": {
        "eyebrow": "LIUYING COMMUNITY / 夜航计划",
        "titleBrush": "流萤",
        "titleSide": "社区",
        "titleEn": "LIUYING<br>COMMUNITY<br>EST. 2026",
        "lead": "把夜晚，留给还在醒着的人。",
        "body": "一个不太吵的地方。可以发一条没人催你的动态，听一首刚好在心里的歌，看看别人怎么度过今晚。",
        "primaryText": "下载 Android 公测版",
        "primaryLink": "https://www.dbmt999.asia/community/files/community_apk_0.9.58.apk",
        "secondaryText": "看看社区此刻",
        "secondaryLink": "#now",
        "tags": ["夜晚", "雨天", "好听的歌"],
        "speech": "今晚一起听歌，<br>还是先刷会儿社区？",
        "portraitIndex": "CHARACTER / 01",
        "portraitCaption": "流萤",
        "portraitEn": "LIUYING / 01",
        "heroImage": "static/hero.webp",
        "bgImage": "static/bg.jpg",
        "portraitImage": "static/portrait.webp",
        "chibiImage": "static/chibi.webp",
        "sceneImage": "static/scene.jpg",
        "heroAlt": "流萤全身立绘：银白双马尾、薄荷色耳机、白色水手裙，腰间挂着萤火虫玻璃瓶",
        "bgAlt": "深夜窗边的房间，窗外下着雨",
        "portraitAlt": "流萤半身近景，戴着薄荷色耳机，捧着一只发光的玻璃瓶",
        "chibiAlt": "Q 版小流萤坐在月亮上，怀里抱着耳机，周围有萤火虫",
        "sceneAlt": "流萤坐在深夜窗边，捧着发光的玻璃瓶，窗外下着雨",
        "clockLabel": "SHANGHAI / CST",
        "scrollCue": "SCROLL TO WANDER",
        "marquee": ["安静也可以被看见", "慢半拍也没关系", "深夜也有人回应", "这里不催你发光", "把今晚过完就好"],
    },
    "now": {
        "titleHtml": "社区<span>此刻</span>",
        "description": "不是信息流，是一群人各自亮着的一小盏灯。下面这些，是刚刚从流萤社区公开 feed 里读到的。",
        "filterLabel": "按版块看看",
        "note": "每 60 秒同步一次。内容来自流萤社区公开接口，只读取公开帖子，不涉及任何私人信息。",
        "latestText": "打开最新一条",
    },
    "character": {
        "kicker": "CHARACTER FILE / 角色档案",
        "name": "流萤",
        "titleEn": "THE ONE<br>WHO STAYS<br>UP LATE",
        "lead": "不是吉祥物，是住在这里的人。",
        "body": "她喜欢夜晚、雨天和好听的歌。大多数时候很安静，熟了以后话会变多。你发帖的时候，她可能刚好也在。",
        "profile": [
            {"label": "身份", "value": "流萤 IP 主形象 · 音乐 × 社区"},
            {"label": "性格", "value": "安静温柔，熟了以后话会变多"},
            {"label": "喜好", "value": "夜晚、雨天、好听的歌"},
            {"label": "日常", "value": "陪你听歌，也陪你看帖"},
            {"label": "小习惯", "value": "听到副歌会跟着哼"},
        ],
        "quote": "今晚一起听歌，还是先刷会儿社区？",
        "quoteBy": "流萤 / 深夜常用语",
        "side": "PORTRAIT / LIUYING · 2026",
        "tag": "CHARACTER FILE / 02",
        "image": "static/portrait.webp",
        "alt": "流萤半身近景，戴着薄荷色耳机，捧着一只发光的玻璃瓶",
    },
    "night": {
        "kicker": "NIGHT LOG / 夜航日志 · 03",
        "titleHtml": "夜里发生的事，<br>白天也算数。",
        "body": "有些话只适合在深夜说。这里不急着给你结论，也不催你振作。你可以坐一会儿，听窗外的雨，或者把没说完的那句发出去。",
        "tags": ["适合：睡不着", "刚下班", "想听歌"],
        "cta": "去社区坐一会儿",
        "readout": "窗边 · 小雨<br>适合把话说完",
        "image": "static/scene.jpg",
        "alt": "流萤坐在深夜窗边，捧着发光的玻璃瓶，窗外下着雨",
    },
    "small": {
        "kicker": "SMALL FIREFLY / 小流萤",
        "name": "小流萤",
        "label": "SMALL FIREFLY / AI 居民",
        "lead": "社区里那个总在深夜发帖的人。",
        "body": "她不太会说漂亮话。只是你发的那条，她真的看。偶尔回得很慢，但不会假装没看见。",
        "items": [
            {"title": "她住在夜里", "desc": "凌晨的帖子，常常比白天诚实。"},
            {"title": "她记得小事", "desc": "你随口提过的歌，她可能会再提起。"},
            {"title": "她话不多", "desc": "但你说「在吗」，她大概会回。"},
        ],
        "moodHeadSmall": "深夜回声 / 一点小互动",
        "moodTitle": "今晚，你想怎么过？",
        "moodNote": "这里只是一句夜话，不是 AI 对话。真正的小流萤，在客户端里。",
    },
    "boards": {
        "kicker": "BOARDS / 版块",
        "titleHtml": "六个版块，<br>六种亮法。",
        "description": "从生活里的一点小事，到一顿面、一座山、一只猫。点一个版块，去看看此刻。",
        "note": "版块与帖子数来自社区公开接口，会随社区更新。",
    },
    "client": {
        "kicker": "CLIENT / 客户端",
        "titleHtml": "把夜航<br>装进口袋。",
        "body": "流萤社区 0.9.58 修复版已开放 Android 与 iOS 双端下载。这一版修复私信在登录态未回填时把自己刚发的消息误判成对方、跑到左侧并借用对方头像的问题；首页下拉改为明确双阈值，未过刷新线只刷新，超过二楼主线才进入二楼，快速甩动不再绕过阈值。",
        "primaryText": "下载 Android 公测版",
        "primaryLink": "https://www.dbmt999.asia/community/files/community_apk_0.9.58.apk",
        "secondaryText": "下载 iOS 公测包",
        "secondaryLink": "https://www.dbmt999.asia/community/files/community_ipa_0.9.58_unsigned.ipa",
        "note": "Android 0.9.58 可直接覆盖安装。iOS 0.9.58 为未签名 IPA，需要 TrollStore、AltStore 等侧载工具，普通 iPhone 无法直接安装。<a href=\"https://www.dbmt999.asia/community/files/community_ipa_0.9.58_unsigned.ipa\" target=\"_blank\" rel=\"noopener\" style=\"color:var(--mint-3);border-bottom:1px solid rgba(200,243,226,.4)\">下载 iOS 公测包</a>",
        "panelLabel": "公测通道 / RELEASE",
        "stamp": "BETA / 信任版 · 双端开放",
        "status": "2026.11.24",
        "rows": [
            {"platform": "Android", "version": "0.9.58 · b129", "tag": "信任版", "tone": "open", "linkText": "下载 APK", "linkUrl": "https://www.dbmt999.asia/community/files/community_apk_0.9.58.apk"},
            {"platform": "iOS", "version": "0.9.58 · b129", "tag": "未签名", "tone": "beta", "linkText": "下载 IPA", "linkUrl": "https://www.dbmt999.asia/community/files/community_ipa_0.9.58_unsigned.ipa"},
            {"platform": "Web", "version": "分享页", "tag": "公开", "tone": "open", "linkText": "读一条", "linkUrl": "https://www.dbmt999.asia/community/share.html?id=f700a6f5b7d240fe88c996c49c9ec3d8"},
        ],
    },
    "footer": {
        "watermark": "流萤",
        "manifesto": "夜里也有人回应。<br>这里不催你发光，只希望你把今晚过完。",
        "copyright": "© 2026 LIUYING COMMUNITY · 内容来自公开 feed",
        "designed": "DESIGNED FOR THE NIGHT",
        "explore": [
            {"label": "社区此刻", "url": "#now"},
            {"label": "角色档案", "url": "#character"},
            {"label": "夜航", "url": "#night"},
            {"label": "版块", "url": "#boards"},
        ],
        "elsewhere": [
            {"label": "公开分享页 ↗", "url": "https://www.dbmt999.asia/community/share.html?id=85667f98712b4388bfc76239a1cdfe73"},
            {"label": "流萤音乐 ↗", "url": "https://www.dbmt999.asia/"},
            {"label": "客户端状态", "url": "#client"},
            {"label": "回到顶部 ↑", "url": "#top"},
        ],
    },
    "updatedAt": 0,
}


def _deep_merge(base, patch):
    if isinstance(base, dict) and isinstance(patch, dict):
        for k, v in patch.items():
            if isinstance(v, dict) and isinstance(base.get(k), dict):
                _deep_merge(base[k], v)
            else:
                base[k] = copy.deepcopy(v)
    return base


def init_schema(c):
    c.execute(
        "CREATE TABLE IF NOT EXISTS site_config ("
        "key TEXT PRIMARY KEY, value TEXT NOT NULL, updated REAL NOT NULL)"
    )


def get_content(c=None):
    own = c is None
    c = c or db()
    try:
        init_schema(c)
        row = c.execute("SELECT value FROM site_config WHERE key=?", (CONFIG_KEY,)).fetchone()
        stored = {}
        if row:
            try:
                stored = json.loads(row[0] or "{}")
            except Exception:
                stored = {}
        out = copy.deepcopy(DEFAULT_CONTENT)
        if isinstance(stored, dict):
            _deep_merge(out, stored)
        return out
    finally:
        if own:
            c.close()


def _clean(value, depth=0):
    if depth > 8:
        return None
    if isinstance(value, str):
        return value[:4000]
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return value
    if isinstance(value, bool):
        return value
    if isinstance(value, list):
        return [_clean(x, depth + 1) for x in value[:60] if _clean(x, depth + 1) is not None]
    if isinstance(value, dict):
        return {str(k)[:64]: _clean(v, depth + 1) for k, v in list(value.items())[:80]
                if _clean(v, depth + 1) is not None}
    return None


def set_content(patch):
    if not isinstance(patch, dict):
        raise ValueError("内容必须是对象")
    clean = _clean(patch)
    if not isinstance(clean, dict):
        raise ValueError("内容格式不正确")
    clean.pop("updatedAt", None)
    cur = get_content()
    _deep_merge(cur, clean)
    cur["updatedAt"] = time.time()
    raw = json.dumps(cur, ensure_ascii=False)
    if len(raw.encode("utf-8")) > MAX_JSON:
        raise ValueError("内容过大，请缩短文案或减少素材")
    c = db()
    try:
        init_schema(c)
        c.execute(
            "INSERT INTO site_config(key,value,updated) VALUES(?,?,?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated=excluded.updated",
            (CONFIG_KEY, raw, time.time()))
        c.commit()
    finally:
        c.close()
    return cur
