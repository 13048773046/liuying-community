# -*- coding: utf-8 -*-
"""流萤工坊 · A 侧核心（按豆包工作模式对标）。

对齐点：
  1) 额度 = 5 小时窗口 + 7 天窗口 + 月额度，三者取最小，任一耗尽即停
  2) 文件 = 临时区（随沙箱销毁）/ 持久区（跟账号走，按 TTL 清）/ 技能区（永久）
  3) 沙箱 = 闲置 30 分钟休眠、24 小时销毁；销毁只清临时区
  4) 授权 = 始终询问 / 按需确认 / 全部允许，默认按需确认
  5) 项目 = 一组资料 + 会话，项目文件自动作上下文
  6) 上下文 = 历史摘要 + 最近 20 条 + 工具结果二次压缩
  7) 缓存率 = 记录 DeepSeek prompt_cache_hit / miss
"""
import os
import json
import time
import sqlite3
import threading
import urllib.error
import urllib.request
import uuid as _uuid

from core.security import validate_outbound_url

AF_BASE = os.environ.get("AF_BASE", "/www/wwwroot/Yosar-community/data/af")
MUSIC_AI_CFG = "/www/wwwroot/music/config/ai_config.json"


class _SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        ok, _ = validate_outbound_url(
            newurl, allow_private=os.environ.get("COMMUNITY_ALLOW_PRIVATE_OUTBOUND") == "1")
        if not ok:
            raise urllib.error.HTTPError(newurl, code, "redirect blocked", headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _safe_urlopen(req, timeout):
    opener = urllib.request.build_opener(_SafeRedirectHandler)
    return opener.open(req, timeout=timeout)

# 额度：三档同时扣，取最小
# 额度：赠送 token（gift_left）先扣，扣完按模型单价扣余额（balance，单位分）
LIMITS = {
    "free": {"w5h": 20000, "d7": 0, "month": 0, "unit": "token", "gift": 30000},
    "vip": {"w5h": 80000, "d7": 0, "month": 0, "unit": "token", "gift": 1000000},
    "svip": {"w5h": 200000, "d7": 0, "month": 0, "unit": "token", "gift": 3000000},
}
# 售价（分/百万 token）= 成本×约1.4，保证不亏且有薄利
PRICE = {
    "deepseek-flash":   {"in": 300,  "out": 900},
    "deepseek-v4-pro":  {"in": 900,  "out": 2700},
}
DEFAULT_MODEL = "deepseek-flash"
# 视觉能力路由：deepseek-v4-pro 是纯文本模型，图片必须交给有视觉编码器的
# deepseek-flash；否则服务端会把 image_url 原样发过去，必然返回
# Unsupported Image。客户端此前只会改格式，解决不了模型能力问题。
VISION_FALLBACK_MODEL = "deepseek-flash"
TEXT_ONLY_MODELS = {"deepseek-v4-pro"}


def route_model_for_vision(model, has_image, custom=False):
    """带图请求遇到纯文本模型时，自动切到视觉模型。

    自建 provider 不在这里改：它的视觉能力由用户配置决定，强行改模型会
    破坏用户自定义端点。返回 (实际模型, 是否发生视觉路由)。
    """
    m = (model or "").strip()
    if has_image and not custom and m in TEXT_ONLY_MODELS:
        return VISION_FALLBACK_MODEL, True
    return m, False
STORAGE = {"free": 100, "vip": 500, "svip": 1024}  # MB

CTX_MAX_MSGS = 20
CTX_CHAR_BUDGET = 24000
# 推理档位：LOW / MEDIUM / HIGH / XHIGH / ULTRA（ULTRA = max + 多轮工具自检）
EFFORT_COEF = {"none": 1.0, "fast": 1.0, "low": 1.0, "think": 1.15, "medium": 1.15,
               "high": 1.35, "deep": 1.6, "xhigh": 1.6, "max": 2.0, "ultra": 2.0}
EFFORT_MAP = {"fast": "low", "think": "medium", "deep": "xhigh",
              "low": "low", "medium": "high", "high": "high",
              "xhigh": "max", "ultra": "max"}
EFFORT_TOKENS = {"low": 4096, "medium": 8192, "high": 12288, "xhigh": 16384, "ultra": 32768}
EFFORT_ROUNDS = {"low": 4, "medium": 6, "high": 8, "xhigh": 10, "ultra": 12}

SANDBOX_IDLE_SLEEP = 30 * 60      # 30 分钟休眠
SANDBOX_IDLE_DESTROY = 24 * 3600  # 24 小时销毁
FILES_ROOT = "/www/wwwroot/Yosar-community/files/af"   # 附件根目录
FILE_TTL = 7 * 86400              # 持久区 7 天未访问清理
HIST_TTL = 30 * 86400             # 会话与消息服务端保留 30 天

TEMPLATE = """
CREATE TABLE IF NOT EXISTS conversations (
  id TEXT PRIMARY KEY, title TEXT DEFAULT '', model TEXT DEFAULT '', effort TEXT DEFAULT 'think',
  summary TEXT DEFAULT '', pinned INTEGER DEFAULT 0, project_id TEXT DEFAULT '',
  created REAL DEFAULT 0, updated REAL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY, conv_id TEXT NOT NULL, role TEXT DEFAULT '', content TEXT DEFAULT '',
  reasoning TEXT DEFAULT '', tokens_in INTEGER DEFAULT 0, tokens_out INTEGER DEFAULT 0,
  cache_hit INTEGER DEFAULT 0, cache_miss INTEGER DEFAULT 0, created REAL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_msg_conv ON messages(conv_id, created);
CREATE TABLE IF NOT EXISTS conv_items (
  id TEXT PRIMARY KEY, conv_id TEXT NOT NULL, payload TEXT DEFAULT '', created REAL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_ci_conv ON conv_items(conv_id, created);
CREATE TABLE IF NOT EXISTS providers (
  id TEXT PRIMARY KEY, name TEXT DEFAULT '', base TEXT DEFAULT '', key TEXT DEFAULT '',
  created REAL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS provider_models (
  id TEXT PRIMARY KEY, provider_id TEXT NOT NULL, model TEXT DEFAULT '', label TEXT DEFAULT '',
  enabled INTEGER DEFAULT 1, created REAL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_pm_prov ON provider_models(provider_id);
CREATE TABLE IF NOT EXISTS files (
  id TEXT PRIMARY KEY, path TEXT DEFAULT '', size INTEGER DEFAULT 0, mime TEXT DEFAULT '',
  zone TEXT DEFAULT 'persist', project_id TEXT DEFAULT '', pinned INTEGER DEFAULT 0,
  last_access REAL DEFAULT 0, expire_at REAL DEFAULT 0, created REAL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_files_exp ON files(expire_at);
CREATE TABLE IF NOT EXISTS usage (
  id TEXT PRIMARY KEY, model TEXT DEFAULT '', effort TEXT DEFAULT '', tokens_in INTEGER DEFAULT 0,
  tokens_out INTEGER DEFAULT 0, cache_hit INTEGER DEFAULT 0, cache_miss INTEGER DEFAULT 0,
  cost INTEGER DEFAULT 0, kind TEXT DEFAULT 'chat', created REAL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_usage_created ON usage(created);
CREATE TABLE IF NOT EXISTS cmd_log (
  id TEXT PRIMARY KEY, conv_id TEXT DEFAULT '', cmd TEXT DEFAULT '', exit_code INTEGER DEFAULT 0,
  ms INTEGER DEFAULT 0, created REAL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS projects (
  id TEXT PRIMARY KEY, name TEXT DEFAULT '', created REAL DEFAULT 0, updated REAL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS bills (
  id TEXT PRIMARY KEY, uid TEXT DEFAULT '', kind TEXT DEFAULT '', model TEXT DEFAULT '',
  tokens_in INTEGER DEFAULT 0, tokens_out INTEGER DEFAULT 0, fen INTEGER DEFAULT 0,
  gift INTEGER DEFAULT 0, note TEXT DEFAULT '', created REAL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS memory (
  id TEXT PRIMARY KEY, uid TEXT DEFAULT '', kind TEXT DEFAULT 'fact',
  content TEXT DEFAULT '', created REAL DEFAULT 0, updated REAL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_mem_uid ON memory(uid);
"""

_pool = {}
_plock = threading.Lock()


def uuid_hex():
    return _uuid.uuid4().hex


def uid_of(x):
    return (x or "").strip()


def user_db(uid):
    uid = uid_of(uid)
    with _plock:
        con = _pool.get(uid)
        if con is not None:
            try:
                con.execute("SELECT 1")
                return con
            except Exception:
                _pool.pop(uid, None)
        d = os.path.join(AF_BASE, uid)
        os.makedirs(d, exist_ok=True)
        os.makedirs(os.path.join(d, "files"), exist_ok=True)
        os.makedirs(os.path.join(d, "skills"), exist_ok=True)
        con = sqlite3.connect(os.path.join(d, "work.db"), check_same_thread=False)
        con.executescript(TEMPLATE)
        con.commit()
        con.row_factory = sqlite3.Row
        if len(_pool) > 50:
            _pool.pop(next(iter(_pool)))
        _pool[uid] = con
        return con


def ai_cfg():
    try:
        with open(MUSIC_AI_CFG, encoding="utf-8") as f:
            return (json.loads(f.read() or "{}").get("chat") or {})
    except Exception:
        return {}


def deepseek_cfg():
    cfg = ai_cfg()
    return {
        "base": cfg.get("base") or "https://api.deepseek.com",
        "key": cfg.get("key") or os.environ.get("AI_API_KEY", ""),
        "model": cfg.get("model") or "deepseek-v4-pro",
        "effort": cfg.get("effort") or {"fast": "disabled", "think": "low", "deep": "high"},
    }


def plan_of_level(level):
    if level == "svip":
        return "svip"
    if level in ("member", "vip"):
        return "vip"
    return "free"


def member_level(c, uid):
    try:
        r = c.execute("SELECT level, expire FROM community_members WHERE user_id=?", (uid,)).fetchone()
    except Exception:
        return ""
    if not r:
        return ""
    lv, exp = (r[0] or ""), (r[1] or 0)
    if exp and exp < time.time():
        return ""
    return lv


def tenant(c, uid):
    now = time.time()
    r = c.execute(
        "SELECT plan,quota_month,quota_used,quota_reset_at,status,expire_at,storage_quota,"
        "settings FROM af_tenants WHERE user_id=?", (uid,)).fetchone()
    lv = member_level(c, uid)
    plan = plan_of_level(lv)
    if not r:
        lim = LIMITS[plan]
        c.execute(
            "INSERT INTO af_tenants(user_id,plan,quota_month,quota_used,quota_reset_at,status,"
            "storage_quota,db_path,settings,created,updated,last_active) "
            "VALUES(?,?,?,0,?,?,?,?,?,?,?,?)",
            (uid, plan, lim["month"], now, "active" if plan != "free" else "trial",
             STORAGE[plan], os.path.join(AF_BASE, uid, "work.db"),
             json.dumps({"auth_mode": "confirm"}), now, now, now))
        c.commit()
        return {"plan": plan, "quota_month": lim["month"], "quota_used": 0,
                "quota_reset_at": now, "status": "active" if plan != "free" else "trial",
                "storage_quota": STORAGE[plan], "settings": {"auth_mode": "confirm"}}
    d = dict(zip(["plan", "quota_month", "quota_used", "quota_reset_at", "status", "expire_at",
                  "storage_quota", "settings"], r))
    if d["plan"] != plan:
        d["plan"] = plan
        d["quota_month"] = LIMITS[plan]["month"]
        d["status"] = "active" if plan != "free" else "trial"
        c.execute("UPDATE af_tenants SET plan=?,quota_month=?,status=?,updated=? WHERE user_id=?",
                  (plan, d["quota_month"], d["status"], now, uid))
    if now - (d["quota_reset_at"] or 0) > 30 * 86400 and d["quota_month"] > 0:
        d["quota_used"] = 0
        c.execute("UPDATE af_tenants SET quota_used=0,quota_reset_at=?,updated=? WHERE user_id=?",
                  (now, now, uid))
    try:
        d["settings"] = json.loads(d.get("settings") or "{}")
    except Exception:
        d["settings"] = {}
    d.setdefault("settings", {})
    d["settings"].setdefault("auth_mode", "confirm")
    try:
        c.execute("ALTER TABLE af_tenants ADD COLUMN balance INTEGER DEFAULT 0")
    except Exception:
        pass
    try:
        c.execute("ALTER TABLE af_tenants ADD COLUMN gift_left INTEGER DEFAULT 0")
    except Exception:
        pass
    try:
        c.execute("ALTER TABLE af_tenants ADD COLUMN gift_init INTEGER DEFAULT 0")
    except Exception:
        pass
    rb = c.execute("SELECT balance,gift_left,gift_init FROM af_tenants WHERE user_id=?", (uid,)).fetchone()
    d["balance"] = int(rb[0] or 0) if rb else 0
    d["gift_left"] = int(rb[1] or 0) if rb else 0
    if rb:
        gi = int(rb[2] or 0)
        g = LIMITS[plan]["gift"]
        if gi == 0 and d["gift_left"] == 0:
            # 首次使用工坊自动发放
            c.execute("UPDATE af_tenants SET gift_left=?,gift_init=? WHERE user_id=?", (g, g, uid))
            d["gift_left"] = g
        elif g > gi:
            # 会员档位升级（或此前被误判为 free 少发），补足差额
            add = g - gi
            c.execute("UPDATE af_tenants SET gift_left=gift_left+?,gift_init=? WHERE user_id=?", (add, g, uid))
            d["gift_left"] = int(d["gift_left"] or 0) + add
    c.execute("UPDATE af_tenants SET last_active=? WHERE user_id=?", (now, uid))
    c.commit()
    return d


def windows(uid):
    """最近 5 小时 / 7 天的已用（count 或 token）。"""
    u = user_db(uid)
    now = time.time()
    r5 = u.execute("SELECT COUNT(*), COALESCE(SUM(cost),0) FROM usage WHERE created>?",
                   (now - 5 * 3600,)).fetchone()
    r7 = u.execute("SELECT COALESCE(SUM(cost),0) FROM usage WHERE created>?",
                   (now - 7 * 86400,)).fetchone()
    return {"w5h": int(r5[0] or 0), "w5h_cost": int(r5[1] or 0), "d7_cost": int(r7[0] or 0)}


def quota_state(c, uid):
    """三档额度状态：任一耗尽即不可用；返回最紧的那个当剩余。"""
    t = tenant(c, uid)
    plan = t["plan"]
    lim = LIMITS[plan]
    w = windows(uid)
    # 全档统一 token 口径；未启用的窗口不参与「取最小」
    BIG = 10 ** 9
    m_left = (max((t["quota_month"] or 0) - (t["quota_used"] or 0), 0)
              if lim["month"] else BIG)
    l5 = max(lim["w5h"] - w["w5h_cost"], 0)
    l7 = (max(lim["d7"] - w["d7_cost"], 0) if lim["d7"] else BIG)
    left = min(m_left, l5, l7)
    blocked = ""
    if left <= 0:
        blocked = "month" if m_left <= 0 else ("w5h" if l5 <= 0 else "d7")
    gift = int(t.get("gift_left") or 0)
    bal = int(t.get("balance") or 0)
    p0 = PRICE[DEFAULT_MODEL]
    per_tok = (p0["out"] or 1) / 1e6   # 分/token
    bal_tok = int(bal / per_tok) if per_tok > 0 else 0
    left = gift + bal_tok
    blocked = "" if left > 0 else "recharge"
    return {"plan": plan, "unit": "token", "left": left, "month_left": (int(m_left) if m_left < BIG else 0),
            "w5h_left": int(l5), "d7_left": (int(l7) if l7 < BIG else 0), "limit_w5h": lim["w5h"], "limit_d7": lim["d7"],
            "limit_month": lim["month"], "blocked_by": blocked,
            "gift_left": gift, "balance": bal, "balance_yuan": round(bal / 100.0, 2),
            "need_recharge": (blocked != "" and gift <= 0 and bal <= 0)}


def price_fen(model, tin, tout):
    p = PRICE.get(model) or PRICE[DEFAULT_MODEL]
    return int(round(tin * p["in"] / 1e6 + tout * p["out"] / 1e6))


# 生图计价（分/张）：只对「用官方 key」的生图扣额度；用户自带 key 不扣
IMG_FEN = {"Kwai-Kolors/Kolors": 4, "Qwen/Qwen-Image": 6, "Tongyi-MAI/Z-Image-Turbo": 5}
IMG_FEN_DEFAULT = 5


def image_quote(model, count=1):
    """把一张图的成本折算成 token 口径，与赠送额度统一。"""
    fen = (IMG_FEN.get(model) or IMG_FEN_DEFAULT) * max(1, int(count))
    per = (PRICE[DEFAULT_MODEL]["out"] or 1) / 1e6   # 分/token
    tok = max(1, int(round(fen / per))) if per > 0 else fen
    return {"tokens": tok, "fen": fen}


def charge_image(c, uid, model, count=1, conv_id=""):
    """扣生图额度：先扣赠送 token（按 token 等值），不足部分扣余额（分）。"""
    q = image_quote(model, count)
    tok, fen_due = q["tokens"], q["fen"]
    t = tenant(c, uid)
    gift = int(t.get("gift_left") or 0)
    gift_used = min(gift, tok)
    rest = tok - gift_used
    if rest > 0 and tok:
        fen_due = int(round(fen_due * rest / float(tok)))
    bal = int(t.get("balance") or 0)
    fen_used = min(bal, fen_due)
    now = time.time()
    u = user_db(uid)
    u.execute("INSERT INTO bills(id,uid,kind,model,tokens_in,tokens_out,fen,gift,note,created)"
              " VALUES(?,?,?,?,?,?,?,?,?,?)",
              (uuid_hex(), uid, "image", model, 0, tok, fen_used, gift_used, conv_id, now))
    u.execute("INSERT INTO usage(id,model,effort,tokens_in,tokens_out,cache_hit,cache_miss,cost,kind,created)"
              " VALUES(?,?,?,?,?,?,?,?,?,?)",
              (uuid_hex(), model, "", 0, tok, 0, 0, tok, "image", now))
    u.commit()
    c.execute("UPDATE af_tenants SET gift_left=?,balance=?,updated=? WHERE user_id=?",
              (gift - gift_used, bal - fen_used, now, uid))
    c.commit()
    return {"gift": gift_used, "fen": fen_used, "fen_due": fen_due, "tokens": tok,
            "gift_left": gift - gift_used, "balance": bal - fen_used}


def charge(c, uid, model, tin, tout, conv_id="", effort="", hit=0, miss=0):
    """先扣赠送 token，再扣余额，并写 usage 表。返回本次实际扣减明细。"""
    t = tenant(c, uid)
    total_tok = int(tin) + int(tout)
    gift = int(t.get("gift_left") or 0)
    gift_used = min(gift, total_tok)
    rest = total_tok - gift_used
    fen_due = price_fen(model, tin, tout)
    if rest > 0:
        # 赠送没覆盖的部分才动余额，按比例折算
        fen_due = int(round(fen_due * (rest / float(total_tok or 1))))
    bal = int(t.get("balance") or 0)
    fen_used = min(bal, fen_due)
    now = time.time()
    u = user_db(uid)
    u.execute("INSERT INTO bills(id,uid,kind,model,tokens_in,tokens_out,fen,gift,note,created) VALUES(?,?,?,?,?,?,?,?,?,?)",
              (uuid_hex(), uid, "chat", model, int(tin), int(tout), fen_used, gift_used, conv_id, now))
    try:
        u.execute("INSERT INTO usage(id,model,effort,tokens_in,tokens_out,cache_hit,cache_miss,cost,kind,created)"
                  " VALUES(?,?,?,?,?,?,?,?,?,?)",
                  (uuid_hex(), model, effort, int(tin), int(tout), int(hit), int(miss), total_tok, "chat", now))
    except Exception:
        pass
    u.commit()
    c.execute("UPDATE af_tenants SET gift_left=?,balance=? WHERE user_id=?",
              (gift - gift_used, bal - fen_used, uid))
    c.commit()
    return {"gift": gift_used, "fen": fen_used, "fen_due": fen_due,
            "gift_left": gift - gift_used, "balance": bal - fen_used}


def estimate_tokens(s):
    if not s:
        return 0
    cn = sum(1 for ch in s if "\u4e00" <= ch <= "\u9fff")
    return int(cn + (len(s) - cn) / 4) + 1


def build_context(c, uid, conv_id, system_prompt):
    u = user_db(uid)
    rows = u.execute("SELECT role,content FROM messages WHERE conv_id=? ORDER BY created ASC",
                     (conv_id,)).fetchall()
    conv = u.execute("SELECT summary FROM conversations WHERE id=?", (conv_id,)).fetchone()
    summary = (conv["summary"] if conv else "") or ""
    msgs = [{"role": "system", "content": system_prompt}]
    if summary:
        msgs.append({"role": "system", "content": "早前内容摘要：\n" + summary})
    budget = CTX_CHAR_BUDGET - len(system_prompt)
    picked = []
    for r in reversed(rows[-CTX_MAX_MSGS:]):
        t = r["content"] or ""
        if len(t) > budget:
            t = t[:max(budget, 200)] + "…（已截断）"
        budget -= len(t)
        if budget <= 0:
            break
        picked.append({"role": r["role"], "content": t})
    picked.reverse()
    msgs.extend(picked)
    # 项目资料：注入项目文件清单（正文按需检索，避免撑爆上下文）
    try:
        pid = u.execute("SELECT project_id FROM conversations WHERE id=?", (conv_id,)).fetchone()
        if pid and pid["project_id"]:
            files = u.execute("SELECT path,size FROM files WHERE project_id=? LIMIT 20",
                              (pid["project_id"],)).fetchall()
            if files:
                names = "、".join(os.path.basename(f["path"]) for f in files)
                msgs.insert(1, {"role": "system",
                                "content": "本项目资料：" + names + "（需要具体内容时再读取）"})
    except Exception:
        pass
    return msgs


def stream_chat(messages, model, effort, on_delta=None, on_reason=None, tools=None,
                base=None, key=None):
    """流式对话。传 tools 时走 function calling，返回 tool_calls。

    base/key 非空时走用户自填的第三方 OpenAI 兼容服务。
    返回 (content, reasoning, usage, tool_calls)
    """
    cfg = deepseek_cfg()
    base_url = (base or cfg["base"]).rstrip("/")
    api_key = key or cfg["key"]
    if not api_key:
        raise RuntimeError("no_api_key")
    target = base_url + "/chat/completions"
    ok, reason = validate_outbound_url(
        target, allow_private=os.environ.get("COMMUNITY_ALLOW_PRIVATE_OUTBOUND") == "1")
    if not ok:
        raise RuntimeError("unsafe_base_url: " + reason)
    body = {"model": model or cfg["model"], "messages": messages, "stream": True,
            "stream_options": {"include_usage": True}}
    eff = EFFORT_MAP.get(effort) or (cfg.get("effort") or {}).get(effort) or ""
    # fast 档配置成 "disabled"，但 DeepSeek 不接受该值（会 422），直接不传
    if eff and eff != "disabled":
        body["reasoning_effort"] = eff
    mx = EFFORT_TOKENS.get(effort)
    if mx:
        body["max_tokens"] = mx
    if tools:
        body["tools"] = tools
        body["tool_choice"] = "auto"
    req = urllib.request.Request(
        base_url + "/chat/completions",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + api_key},
        method="POST")
    content, reasoning, usage = [], [], {}
    calls = {}
    with _safe_urlopen(req, timeout=180) as resp:
        buf = b""
        for chunk in resp:
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.strip()
                if not line.startswith(b"data:"):
                    continue
                data = line[5:].strip()
                if data == b"[DONE]":
                    break
                try:
                    obj = json.loads(data)
                except Exception:
                    continue
                if obj.get("usage"):
                    usage = obj["usage"]
                for ch in (obj.get("choices") or []):
                    d = ch.get("delta") or {}
                    if d.get("content"):
                        content.append(d["content"])
                        if on_delta:
                            on_delta(d["content"])
                    if d.get("reasoning_content"):
                        reasoning.append(d["reasoning_content"])
                        if on_reason:
                            on_reason(d["reasoning_content"])
                    if d.get("tool_calls"):
                        for tc in d["tool_calls"]:
                            idx = tc.get("index", 0)
                            slot = calls.setdefault(idx, {"id": "", "type": "function",
                                                           "function": {"name": "", "arguments": ""}})
                            if tc.get("id"):
                                slot["id"] = tc["id"]
                            fn = tc.get("function") or {}
                            if fn.get("name"):
                                slot["function"]["name"] = fn["name"]
                            if fn.get("arguments"):
                                slot["function"]["arguments"] += fn["arguments"]
    return ("".join(content), "".join(reasoning), usage,
            [calls[k] for k in sorted(calls.keys())])


def record_usage(c, uid, model, effort, usage, kind="chat"):
    """记录用量（usage 表）。缓存命中按 1/10 计。"""
    tin = int(usage.get("prompt_tokens") or 0)
    tout = int(usage.get("completion_tokens") or 0)
    hit = int(usage.get("prompt_cache_hit_tokens") or 0)
    miss = int(usage.get("prompt_cache_miss_tokens") or 0)
    if not miss and tin:
        miss = max(tin - hit, 0)
    coef = EFFORT_COEF.get(effort, EFFORT_COEF.get(EFFORT_MAP.get(effort, ""), 1.0))
    # 成本口径：命中 tokens 打 1 折
    cost = int((hit * 0.1 + miss) + tout * coef)
    now = time.time()
    c.execute("UPDATE af_tenants SET quota_used=quota_used+?,updated=? WHERE user_id=?",
              (cost, now, uid))
    c.commit()
    u = user_db(uid)
    u.execute("INSERT INTO usage(id,model,effort,tokens_in,tokens_out,cache_hit,cache_miss,cost,kind,created)"
              " VALUES(?,?,?,?,?,?,?,?,?,?)",
              (_uuid.uuid4().hex, model, effort, tin, tout, hit, miss, cost, kind, now))
    u.commit()
    return {"tokens_in": tin, "tokens_out": tout, "cache_hit": hit, "cache_miss": miss, "cost": cost}


def cache_rate(uid):
    u = user_db(uid)
    r = u.execute("SELECT COALESCE(SUM(cache_hit),0), COALESCE(SUM(cache_miss),0) FROM usage").fetchone()
    hit, miss = int(r[0] or 0), int(r[1] or 0)
    total = hit + miss
    return {"hit": hit, "miss": miss, "rate": round(hit / total * 100, 1) if total else 0.0}


# ---------------------------------------------------------------- 沙箱生命周期
def sandbox_row(c, uid):
    r = c.execute("SELECT container_id,status,last_active,created FROM af_sandbox WHERE user_id=?",
                  (uid,)).fetchone()
    if not r:
        return None
    return dict(zip(["container_id", "status", "last_active", "created"], r))


def touch_sandbox(c, uid):
    now = time.time()
    if not sandbox_row(c, uid):
        c.execute("INSERT INTO af_sandbox(user_id,status,last_active,created) VALUES(?,?,?,?)",
                  (uid, "pending", now, now))
    else:
        c.execute("UPDATE af_sandbox SET last_active=? WHERE user_id=?", (now, uid))
    c.commit()


def due_sandboxes(c, sleep_after=SANDBOX_IDLE_SLEEP, destroy_after=SANDBOX_IDLE_DESTROY):
    """后台清扫：返回应休眠 / 应销毁的容器。"""
    now = time.time()
    rows = c.execute("SELECT user_id,container_id,status,last_active FROM af_sandbox "
                     "WHERE status IN ('running','pending')").fetchall()
    sleep, destroy = [], []
    for uid, cid, st, la in rows:
        idle = now - (la or now)
        if idle > destroy_after:
            destroy.append((uid, cid))
        elif idle > sleep_after:
            sleep.append((uid, cid))
    return sleep, destroy


def storage_used(uid):
    d = os.path.join(AF_BASE, uid, "files")
    total = 0
    try:
        for root, _, fs in os.walk(d):
            for f in fs:
                total += os.path.getsize(os.path.join(root, f))
    except Exception:
        pass
    return total
