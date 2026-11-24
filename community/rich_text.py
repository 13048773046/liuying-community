# -*- coding: utf-8 -*-
"""官方通知富文本：把管理端提交的 JSON 文档规范化成客户端可直接渲染的安全结构。

设计目标：
- 只接受白名单块 / 行内样式，客户端不需要解析 HTML，杜绝脚本注入；
- 同时生成纯文本 fallback，旧版客户端、后台列表、推送摘要都能读；
- 文本、块数、链接长度都有硬上限，避免一条通知打爆页面；
- 颜色只允许品牌语义色，避免运营把气泡配成不可读的随机色。
"""
import json
import re
import unicodedata
from urllib.parse import urlsplit

MAX_BLOCKS = 24
MAX_SPANS_PER_BLOCK = 40
MAX_TEXT_TOTAL = 3000
MAX_SPAN_TEXT = 800
MAX_URL = 600

COLOR_TOKENS = {
    "default": "default",
    "accent": "accent",
    "warning": "warning",
    "danger": "danger",
    "muted": "muted",
}
_COLOR_ALIASES = {
    "#45e0ae": "accent",
    "rgb(69,224,174)": "accent",
    "rgba(69,224,174,1)": "accent",
    "#ffb020": "warning",
    "rgb(255,176,32)": "warning",
    "rgba(255,176,32,1)": "warning",
    "#ff4d4f": "danger",
    "rgb(255,77,79)": "danger",
    "rgba(255,77,79,1)": "danger",
    "#b3ffffff": "muted",
    "#ffffff": "default",
    "rgb(255,255,255)": "default",
}
BLOCK_TYPES = {"paragraph", "heading", "quote", "bullet", "image", "divider"}
_CTRL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def _clean_text(value, limit=MAX_SPAN_TEXT):
    text = str(value or "").replace("\r\n", "\n").replace("\r", "\n")
    # 保留换行（软换行 / 粘贴多行都可读），只折叠其它连续空白；
    # 换行不是 HTML，渲染端按 TextSpan 文本换行处理，不存在注入风险。
    text = _CTRL_RE.sub("", text)
    text = re.sub(r"[^\S\n]+", " ", text)
    text = unicodedata.normalize("NFC", text)
    if len(text) > limit:
        text = text[:limit].rstrip()
    return text


def _safe_url(value):
    url = str(value or "").strip()
    if not url or len(url) > MAX_URL:
        return ""
    if any(ch.isspace() for ch in url) or _CTRL_RE.search(url):
        return ""
    try:
        parsed = urlsplit(url)
    except ValueError:
        return ""
    if parsed.scheme.lower() not in ("http", "https"):
        return ""
    if not parsed.netloc or parsed.username or parsed.password:
        return ""
    return url


def _span(raw):
    if not isinstance(raw, dict):
        return None
    text = _clean_text(raw.get("text"))
    if not text:
        return None
    out = {"text": text}
    for key in ("bold", "italic", "underline"):
        if raw.get(key) is True:
            out[key] = True
    color = str(raw.get("color") or "").strip().lower().replace(" ", "")
    token = COLOR_TOKENS.get(color) or _COLOR_ALIASES.get(color)
    if token and token != "default":
        out["color"] = token
    url = _safe_url(raw.get("url"))
    if url:
        out["url"] = url
        out["underline"] = True
    return out


def _spans(raw):
    if not isinstance(raw, list):
        return []
    out = []
    for item in raw[:MAX_SPANS_PER_BLOCK]:
        span = _span(item)
        if span:
            out.append(span)
    return out


def _block(raw):
    if not isinstance(raw, dict):
        return None
    kind = str(raw.get("type") or "paragraph").strip().lower()
    if kind not in BLOCK_TYPES:
        return None
    if kind == "divider":
        return {"type": "divider"}
    if kind == "image":
        url = _safe_url(raw.get("url"))
        if not url:
            return None
        return {
            "type": "image",
            "url": url,
            "alt": _clean_text(raw.get("alt"), 120),
        }
    spans = _spans(raw.get("spans"))
    if not spans:
        return None
    block = {"type": kind, "spans": spans}
    if kind == "heading":
        try:
            level = int(raw.get("level") or 2)
        except (TypeError, ValueError):
            level = 2
        block["level"] = 2 if level <= 2 else 3
    return block


def _plain(blocks):
    lines = []
    for block in blocks:
        kind = block.get("type")
        if kind == "divider":
            lines.append("")
        elif kind == "image":
            lines.append(block.get("alt") or "[图片]")
        else:
            text = "".join(s.get("text", "") for s in block.get("spans", []))
            if kind == "bullet":
                text = "• " + text
            elif kind == "heading":
                text = text
            lines.append(text)
    return "\n".join(lines).strip()[:MAX_TEXT_TOTAL]


def sanitize_official_rich(raw):
    """返回 (canonical_doc, plain_text)；非法时抛 ValueError。"""
    doc = raw
    if isinstance(raw, str):
        try:
            doc = json.loads(raw)
        except (TypeError, ValueError):
            raise ValueError("富文本格式错误")
    if not isinstance(doc, dict):
        raise ValueError("富文本格式错误")
    blocks_raw = doc.get("blocks")
    if not isinstance(blocks_raw, list):
        raise ValueError("富文本缺少 blocks")
    blocks = []
    for item in blocks_raw[:MAX_BLOCKS]:
        block = _block(item)
        if block:
            blocks.append(block)
    if not blocks:
        raise ValueError("富文本内容为空")
    # 总可见字符硬上限：逐个 span 截断，避免多块/多 span 叠加成超长 payload。
    total = 0
    limited = []
    for block in blocks:
        if block.get("type") in ("divider", "image"):
            limited.append(block)
            continue
        spans = []
        for span in block.get("spans", []):
            remaining = MAX_TEXT_TOTAL - total
            if remaining <= 0:
                break
            text = span.get("text", "")[:remaining].rstrip()
            if not text:
                continue
            item = dict(span)
            item["text"] = text
            spans.append(item)
            total += len(text)
        if spans:
            block = dict(block)
            block["spans"] = spans
            limited.append(block)
    blocks = limited
    if not blocks:
        raise ValueError("富文本内容为空")
    plain = _plain(blocks)
    if not plain and not any(b.get("type") == "image" for b in blocks):
        raise ValueError("富文本内容为空")
    canonical = {"v": 1, "blocks": blocks}
    return canonical, plain
