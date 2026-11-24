# -*- coding: utf-8 -*-
"""流萤社区 · 邀请返现核心逻辑。

约束：
- 只操作 community_* / invite_* 自有表，不动音乐共享表结构；
- 奖励全部走台账，不直接改余额，提现和返佣都可追溯；
- 有效邀请只认「新账号 + 点击归因 + 手机号验证」，避免老用户被反复计数；
- 现金规则默认有月上限和总预算，先控成本再放量。
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import io
import json
import os
import random
import re
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from core.settings import settings

PUBLIC_BASE = (os.environ.get("COMMUNITY_INVITE_PUBLIC_BASE")
               or "https://www.dbmt999.asia").rstrip("/")
def _qr_dir():
    """二维码目录：显式环境变量优先；否则跟着当前数据库路径。"""
    return (os.environ.get("COMMUNITY_INVITE_QR_DIR")
            or os.path.join(os.path.dirname(os.environ.get("COMMUNITY_DB")
                                           or settings.db_path), "invite_qr"))


QR_DIR = _qr_dir()
SMS_CONFIGS = [
    os.environ.get("COMMUNITY_SMS_CONFIG", "/www/wwwroot/yosar-data/config/sms.json"),
    os.environ.get("COMMUNITY_ALIYUN_SMS_CONFIG", "/www/wwwroot/yosar-data/config/aliyun_sms.json"),
    os.environ.get("COMMUNITY_SPUG_SMS_CONFIG", "/www/wwwroot/yosar-data/config/spug_sms.json"),
]
SPUG_SMS_BASE = "https://push.spug.cc/sms/"
SPUG_SEND_BASE = "https://push.spug.cc/send/"
PHONE_RE = re.compile(r"^1[3-9]\d{9}$")

DEFAULTS = {
    "enabled": "1",
    "fixed_reward_cents": "100",       # ¥1 / 有效新用户
    "commission_bps": "2000",          # 会员首单实付的 20%
    "min_withdraw_cents": "1000",      # 满 ¥10 可提现
    "settle_days": "7",                # 奖励冻结 7 天
    "monthly_invite_cap": "30",        # 每个邀请人每月最多 30 个有效邀请
    "monthly_budget_cents": "100000",  # 全站固定奖励月预算 ¥1000
    "invite_expire_days": "7",         # 点击后 7 天内注册可绑定
    "rule_version": "2026-11-24",
    "download_ios": "https://www.dbmt999.asia/community/files/community_ipa_0.9.58_unsigned.ipa",
    "download_android": "https://www.dbmt999.asia/community/files/community_apk_0.9.58.apk",
}

_DDL = [
    """
    CREATE TABLE IF NOT EXISTS community_invite_profiles(
        user_id TEXT PRIMARY KEY,
        code TEXT NOT NULL UNIQUE,
        phone_hash TEXT DEFAULT '',
        phone_mask TEXT DEFAULT '',
        phone_verified_at REAL DEFAULT 0,
        clicks INTEGER DEFAULT 0,
        valid_count INTEGER DEFAULT 0,
        total_earned_cents INTEGER DEFAULT 0,
        total_withdrawn_cents INTEGER DEFAULT 0,
        share_count INTEGER DEFAULT 0,
        created REAL,
        updated REAL
    )""",
    "CREATE UNIQUE INDEX IF NOT EXISTS uq_invite_profile_phone "
    "ON community_invite_profiles(phone_hash) WHERE phone_hash<>''",
    """
    CREATE TABLE IF NOT EXISTS community_invite_clicks(
        id TEXT PRIMARY KEY,
        code TEXT NOT NULL,
        inviter_id TEXT NOT NULL,
        ip TEXT DEFAULT '',
        ua TEXT DEFAULT '',
        created REAL,
        consumed INTEGER DEFAULT 0,
        invitee_id TEXT DEFAULT ''
    )""",
    "CREATE INDEX IF NOT EXISTS idx_invite_click_code ON community_invite_clicks(code, created DESC)",
    """
    CREATE TABLE IF NOT EXISTS community_invite_shares(
        id TEXT PRIMARY KEY,
        code TEXT NOT NULL,
        inviter_id TEXT NOT NULL,
        action TEXT DEFAULT 'copy',
        ip TEXT DEFAULT '',
        ua TEXT DEFAULT '',
        created REAL
    )""",
    "CREATE INDEX IF NOT EXISTS idx_invite_share_code ON community_invite_shares(code, created DESC)",
    """
    CREATE TABLE IF NOT EXISTS community_phone_accounts(
        phone_hash TEXT PRIMARY KEY,
        phone_mask TEXT DEFAULT '',
        user_id TEXT NOT NULL UNIQUE,
        created REAL,
        verified_at REAL
    )""",
    """
    CREATE TABLE IF NOT EXISTS community_invite_bindings(
        id TEXT PRIMARY KEY,
        inviter_id TEXT NOT NULL,
        invitee_id TEXT NOT NULL UNIQUE,
        code TEXT DEFAULT '',
        click_id TEXT DEFAULT '',
        status TEXT DEFAULT 'pending',
        phone_hash TEXT DEFAULT '',
        phone_mask TEXT DEFAULT '',
        reward_cents INTEGER DEFAULT 0,
        commission_cents INTEGER DEFAULT 0,
        first_order_id TEXT DEFAULT '',
        created REAL,
        verified_at REAL DEFAULT 0,
        valid_at REAL DEFAULT 0,
        risk TEXT DEFAULT '',
        note TEXT DEFAULT ''
    )""",
    "CREATE INDEX IF NOT EXISTS idx_invite_bind_inviter ON community_invite_bindings(inviter_id, created DESC)",
    "CREATE INDEX IF NOT EXISTS idx_invite_bind_status ON community_invite_bindings(status)",
    "CREATE UNIQUE INDEX IF NOT EXISTS uq_invite_bind_phone "
    "ON community_invite_bindings(phone_hash) WHERE phone_hash<>''",
    """
    CREATE TABLE IF NOT EXISTS community_invite_phone_codes(
        phone_hash TEXT PRIMARY KEY,
        code_hash TEXT NOT NULL,
        created REAL,
        expires REAL,
        attempts INTEGER DEFAULT 0,
        ip TEXT DEFAULT ''
    )""",
    """
    CREATE TABLE IF NOT EXISTS community_invite_phone_log(
        id TEXT PRIMARY KEY,
        phone_hash TEXT NOT NULL,
        ip TEXT DEFAULT '',
        created REAL
    )""",
    "CREATE INDEX IF NOT EXISTS idx_invite_phone_log ON community_invite_phone_log(phone_hash, created DESC)",
    """
    CREATE TABLE IF NOT EXISTS community_invite_ledger(
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        amount_cents INTEGER NOT NULL,
        status TEXT DEFAULT 'frozen',
        ref_id TEXT DEFAULT '',
        available_at REAL DEFAULT 0,
        created REAL,
        note TEXT DEFAULT ''
    )""",
    "CREATE INDEX IF NOT EXISTS idx_invite_ledger_user ON community_invite_ledger(user_id, created DESC)",
    "CREATE INDEX IF NOT EXISTS idx_invite_ledger_status ON community_invite_ledger(status, available_at)",
    """
    CREATE TABLE IF NOT EXISTS community_invite_withdrawals(
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        amount_cents INTEGER NOT NULL,
        name TEXT DEFAULT '',
        phone TEXT DEFAULT '',
        qr_path TEXT DEFAULT '',
        status TEXT DEFAULT 'pending',
        note TEXT DEFAULT '',
        admin_note TEXT DEFAULT '',
        transfer_ref TEXT DEFAULT '',
        created REAL,
        reviewed_at REAL DEFAULT 0,
        paid_at REAL DEFAULT 0
    )""",
    "CREATE INDEX IF NOT EXISTS idx_invite_wd_user ON community_invite_withdrawals(user_id, created DESC)",
    "CREATE INDEX IF NOT EXISTS idx_invite_wd_status ON community_invite_withdrawals(status, created)",
    """
    CREATE TABLE IF NOT EXISTS community_invite_settings(
        k TEXT PRIMARY KEY,
        v TEXT DEFAULT ''
    )""",
]


def init_schema(c):
    for ddl in _DDL:
        c.execute(ddl)
    for k, v in DEFAULTS.items():
        c.execute("INSERT OR IGNORE INTO community_invite_settings(k,v) VALUES(?,?)", (k, v))
    os.makedirs(_qr_dir(), exist_ok=True)


def get_setting(c, key, default=None):
    row = c.execute("SELECT v FROM community_invite_settings WHERE k=?", (key,)).fetchone()
    return row[0] if row else (DEFAULTS.get(key) if default is None else default)


def set_setting(c, key, value):
    c.execute("INSERT INTO community_invite_settings(k,v) VALUES(?,?) "
              "ON CONFLICT(k) DO UPDATE SET v=excluded.v", (key, str(value)))


def settings_dict(c):
    out = {}
    for k in DEFAULTS:
        out[k] = get_setting(c, k)
    return out


def normalize_phone(raw):
    p = re.sub(r"[\s\-()]", "", str(raw or ""))
    if p.startswith("+86"):
        p = p[3:]
    if p.startswith("86") and len(p) == 13:
        p = p[2:]
    return p


def phone_hash(phone):
    salt = os.environ.get("COMMUNITY_INVITE_PHONE_SALT", "liuying-invite-phone-2026")
    return hmac.new(salt.encode(), phone.encode(), hashlib.sha256).hexdigest()


def mask_phone(phone):
    return phone[:3] + "****" + phone[-4:] if len(phone) == 11 else ""


def mask_email(email):
    e = str(email or "")
    if "@" not in e:
        return e[:3] + "***" if e else ""
    a, b = e.split("@", 1)
    return (a[:2] + "***") + "@" + b


def _new_code(c):
    for _ in range(60):
        code = "".join(secrets.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(8))
        if not c.execute("SELECT 1 FROM community_invite_profiles WHERE code=?", (code,)).fetchone():
            return code
    raise RuntimeError("invite_code_generate_failed")


def ensure_profile(c, uid):
    row = c.execute("SELECT code FROM community_invite_profiles WHERE user_id=?", (uid,)).fetchone()
    if row:
        return row[0]
    code = _new_code(c)
    now = time.time()
    c.execute("INSERT INTO community_invite_profiles(user_id,code,created,updated) VALUES(?,?,?,?)",
              (uid, code, now, now))
    c.commit()
    return code


def profile(c, uid):
    return c.execute("SELECT * FROM community_invite_profiles WHERE user_id=?", (uid,)).fetchone()


def invite_url(code):
    return PUBLIC_BASE + "/invite/?ref=" + urllib.parse.quote(code)


def qr_png(code):
    import qrcode
    img = qrcode.make(invite_url(code), box_size=8, border=2)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def balance_state(c, uid):
    rows = c.execute(
        "SELECT amount_cents,status,available_at,kind FROM community_invite_ledger "
        "WHERE user_id=? AND status<>'rejected'", (uid,)).fetchall()
    now = time.time()
    earned = frozen = held = paid = 0
    for amount, status, avail, kind in rows:
        a = int(amount or 0)
        if a > 0:
            if status == "frozen" and (avail or 0) > now:
                frozen += a
            else:
                earned += a
        elif a < 0:
            if status == "pending" or status == "approved":
                held += -a
            elif status == "paid":
                paid += -a
    available = max(0, earned - held - paid)
    return {"available_cents": available, "frozen_cents": frozen,
            "earned_cents": earned + frozen, "withdrawn_cents": paid}


def month_start():
    lt = time.localtime()
    return time.mktime((lt.tm_year, lt.tm_mon, 1, 0, 0, 0, 0, 0, -1))


def add_ledger(c, uid, kind, amount_cents, ref_id="", status="frozen",
               available_at=0, note=""):
    if not amount_cents:
        return ""
    lid = uuid.uuid4().hex
    c.execute("INSERT INTO community_invite_ledger"
              "(id,user_id,kind,amount_cents,status,ref_id,available_at,created,note)"
              " VALUES(?,?,?,?,?,?,?,?,?)",
              (lid, uid, kind, int(amount_cents), status, ref_id,
               available_at, time.time(), note[:200]))
    if amount_cents > 0:
        c.execute("UPDATE community_invite_profiles SET total_earned_cents="
                  "COALESCE(total_earned_cents,0)+?, updated=? WHERE user_id=?",
                  (int(amount_cents), time.time(), uid))
    return lid


def _monthly_fixed_used(c, inviter_id):
    cap = int(get_setting(c, "monthly_invite_cap", "30") or 30)
    used = c.execute(
        "SELECT COUNT(*) FROM community_invite_bindings WHERE inviter_id=? "
        "AND status='valid' AND reward_cents>0 AND valid_at>=?",
        (inviter_id, month_start())).fetchone()[0]
    return int(used or 0), cap


def _monthly_budget_used(c):
    budget = int(get_setting(c, "monthly_budget_cents", "100000") or 100000)
    used = c.execute(
        "SELECT COALESCE(SUM(amount_cents),0) FROM community_invite_ledger "
        "WHERE kind='fixed' AND amount_cents>0 AND created>=?",
        (month_start(),)).fetchone()[0]
    return int(used or 0), budget


def mark_valid(c, invitee_id):
    """手机号验证成功：把待确认邀请转有效，并发 ¥1 固定奖励。"""
    b = c.execute("SELECT id,inviter_id,status FROM community_invite_bindings "
                  "WHERE invitee_id=?", (invitee_id,)).fetchone()
    if not b or b[2] != "pending":
        return None
    bid, inviter, _ = b
    now = time.time()
    reward = int(get_setting(c, "fixed_reward_cents", "100") or 100)
    cap_used, cap = _monthly_fixed_used(c, inviter)
    budget_used, budget = _monthly_budget_used(c)
    note = ""
    if cap_used >= cap:
        reward = 0
        note = "monthly_invite_cap"
    elif budget_used + reward > budget:
        reward = 0
        note = "monthly_budget_cap"
    c.execute("UPDATE community_invite_bindings SET status='valid', valid_at=?, "
              "verified_at=?, reward_cents=?, note=? WHERE id=?",
              (now, now, reward, note, bid))
    if reward:
        days = int(get_setting(c, "settle_days", "7") or 7)
        add_ledger(c, inviter, "fixed", reward, bid, "frozen",
                   now + days * 86400, "有效邀请奖励")
        c.execute("UPDATE community_invite_profiles SET valid_count=valid_count+1, "
                  "updated=? WHERE user_id=?", (now, inviter))
    # 如果新用户先买了会员、后补手机号，首单 20% 仍要补记
    paid = c.execute("SELECT id,price FROM community_member_orders WHERE user_id=? "
                     "AND status=1 ORDER BY paid_at ASC LIMIT 1", (invitee_id,)).fetchone()
    c.commit()
    if paid:
        credit_membership(c, invitee_id, paid[0], int(paid[1] or 0))
    return {"binding_id": bid, "reward_cents": reward, "note": note}


def bind_invite(c, invitee_id, code, click_id, ip="", ua=""):
    code = (code or "").strip().upper()
    if not code:
        return False, "missing_code"
    prof = c.execute("SELECT user_id FROM community_invite_profiles WHERE code=?", (code,)).fetchone()
    if not prof:
        return False, "invalid_code"
    inviter = prof[0]
    if inviter == invitee_id:
        return False, "self_invite"
    existing = c.execute("SELECT status FROM community_invite_bindings WHERE invitee_id=?",
                         (invitee_id,)).fetchone()
    if existing:
        return False, "already_bound"
    click = c.execute("SELECT id,inviter_id,created,consumed FROM community_invite_clicks "
                      "WHERE id=? AND code=?", (click_id, code)).fetchone()
    if not click:
        return False, "invalid_click"
    if click[3]:
        return False, "click_used"
    expire_days = int(get_setting(c, "invite_expire_days", "7") or 7)
    if time.time() - (click[2] or 0) > expire_days * 86400:
        return False, "click_expired"
    user = c.execute("SELECT created FROM users WHERE id=?", (invitee_id,)).fetchone()
    if not user:
        return False, "user_not_found"
    # 必须是点击之后新注册的账号：老账号不能补绑
    if (user[0] or 0) < (click[2] or 0) - 60:
        return False, "not_new_user"
    now = time.time()
    bid = uuid.uuid4().hex
    pp = profile(c, invitee_id)
    ph = (pp[2] if pp else "") or ""
    pm = (pp[3] if pp else "") or ""
    c.execute("INSERT INTO community_invite_bindings"
              "(id,inviter_id,invitee_id,code,click_id,status,phone_hash,phone_mask,created,risk,note)"
              " VALUES(?,?,?,?,?, 'pending', ?, ?, ?, ?, ?)",
              (bid, inviter, invitee_id, code, click_id, ph, pm, now,
               "" if ip else "", ""))
    c.execute("UPDATE community_invite_clicks SET consumed=1, invitee_id=? WHERE id=?",
              (invitee_id, click_id))
    c.commit()
    if pp and pp[4]:
        valid = mark_valid(c, invitee_id)
        return True, {"binding_id": bid, "inviter_id": inviter,
                      "status": "valid", "valid": valid or {}}
    return True, {"binding_id": bid, "inviter_id": inviter, "status": "pending"}


def record_share(c, code, action="copy", ip="", ua=""):
    """记录“复制链接 / 系统分享”动作，用于统计分享转化。"""
    code = (code or "").strip().upper()
    prof = c.execute("SELECT user_id FROM community_invite_profiles WHERE code=?", (code,)).fetchone()
    if not prof:
        return None
    now = time.time()
    sid = uuid.uuid4().hex
    c.execute("INSERT INTO community_invite_shares(id,code,inviter_id,action,ip,ua,created)"
              " VALUES(?,?,?,?,?,?,?)",
              (sid, code, prof[0], (action or "copy")[:16], ip[:64], ua[:200], now))
    c.execute("UPDATE community_invite_profiles SET share_count=COALESCE(share_count,0)+1, "
              "updated=? WHERE user_id=?", (now, prof[0]))
    c.commit()
    return {"share_id": sid, "inviter_id": prof[0]}


def record_click(c, code, ip="", ua=""):
    code = (code or "").strip().upper()
    prof = c.execute("SELECT user_id FROM community_invite_profiles WHERE code=?", (code,)).fetchone()
    if not prof:
        return None
    now = time.time()
    cid = uuid.uuid4().hex
    c.execute("INSERT INTO community_invite_clicks(id,code,inviter_id,ip,ua,created)"
              " VALUES(?,?,?,?,?,?)", (cid, code, prof[0], ip[:64], ua[:200], now))
    c.execute("UPDATE community_invite_profiles SET clicks=clicks+1, updated=? WHERE user_id=?",
              (now, prof[0]))
    c.commit()
    return {"click_id": cid, "inviter_id": prof[0]}


def sms_config():
    """短信配置：腾讯云、阿里云标准短信、Spug 共享模板；只返回当前可用的一家。"""
    cfg = {}
    for path in SMS_CONFIGS:
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                cfg.update(data)
        except Exception:
            continue
    tencent_env = {
        "secret_id": "COMMUNITY_TENCENT_SMS_SECRET_ID",
        "secret_key": "COMMUNITY_TENCENT_SMS_SECRET_KEY",
        "sdk_app_id": "COMMUNITY_TENCENT_SMS_SDK_APP_ID",
        "sign_name": "COMMUNITY_TENCENT_SMS_SIGN",
        "template_id": "COMMUNITY_TENCENT_SMS_TEMPLATE",
        "region": "COMMUNITY_TENCENT_SMS_REGION",
    }
    aliyun_env = {
        "access_key_id": "COMMUNITY_ALIYUN_SMS_KEY",
        "access_key_secret": "COMMUNITY_ALIYUN_SMS_SECRET",
        "sign_name": "COMMUNITY_ALIYUN_SMS_SIGN",
        "template_code": "COMMUNITY_ALIYUN_SMS_TEMPLATE",
    }
    spug_env = {
        "spug_template_code": "COMMUNITY_SPUG_SMS_TEMPLATE",
        "spug_url": "COMMUNITY_SPUG_SMS_URL",
    }
    for key, env in tencent_env.items():
        if os.environ.get(env):
            cfg[key] = os.environ[env]
    for key, env in aliyun_env.items():
        if os.environ.get(env):
            cfg[key] = os.environ[env]
    for key, env in spug_env.items():
        if os.environ.get(env):
            cfg[key] = os.environ[env]
    provider = str(cfg.get("provider") or os.environ.get("COMMUNITY_SMS_PROVIDER") or "").strip().lower()
    if not provider:
        if cfg.get("spug_template_code") or cfg.get("spug_url"):
            provider = "spug"
        elif cfg.get("secret_id") or cfg.get("sdk_app_id"):
            provider = "tencent"
        else:
            provider = "aliyun"
    if provider == "tencent":
        if not all(str(cfg.get(k) or "").strip() for k in
                   ("secret_id", "secret_key", "sdk_app_id", "sign_name", "template_id")):
            return None
        cfg["provider"] = "tencent"
        cfg.setdefault("region", "ap-guangzhou")
        return cfg
    if provider == "aliyun":
        if not all(str(cfg.get(k) or "").strip() for k in
                   ("access_key_id", "access_key_secret", "sign_name", "template_code")):
            return None
        cfg["provider"] = "aliyun"
        return cfg
    if provider == "spug":
        # Spug 使用平台官方模板，模板编码本身就是调用凭证；不要和阿里云的
        # template_code 混用，避免同时存在两套配置时误取阿里云模板。
        if not (str(cfg.get("spug_template_code") or "").strip()
                or str(cfg.get("spug_url") or "").strip()):
            return None
        cfg["provider"] = "spug"
        return cfg
    return None


def _tencent_hmac(key, msg):
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def send_tencent_sms(phone, code):
    cfg = sms_config()
    if not cfg or cfg.get("provider") != "tencent":
        return False, "sms_not_configured"
    host = "sms.tencentcloudapi.com"
    endpoint = "https://" + host
    region = str(cfg.get("region") or "ap-guangzhou")
    action = "SendSms"
    version = "2021-01-11"
    ts = int(time.time())
    date = time.strftime("%Y-%m-%d", time.gmtime(ts))
    payload = json.dumps({
        "PhoneNumberSet": ["+86" + str(phone)],
        "SmsSdkAppId": str(cfg["sdk_app_id"]),
        "SignName": str(cfg["sign_name"]),
        "TemplateId": str(cfg["template_id"]),
        "TemplateParamSet": [str(code)],
    }, ensure_ascii=False, separators=(",", ":"))
    content_type = "application/json; charset=utf-8"
    canonical_headers = "content-type:%s\nhost:%s\n" % (content_type, host)
    signed_headers = "content-type;host"
    hashed_payload = hashlib.sha256(payload.encode("utf-8")).hexdigest()
    canonical_request = "POST\n/\n\n%s\n%s\n%s" % (
        canonical_headers, signed_headers, hashed_payload)
    string_to_sign = "TC3-HMAC-SHA256\n%d\n%s/sms/tc3_request\n%s" % (
        ts, date, hashlib.sha256(canonical_request.encode("utf-8")).hexdigest())
    secret_date = _tencent_hmac(("TC3" + str(cfg["secret_key"])).encode("utf-8"), date)
    secret_service = _tencent_hmac(secret_date, "sms")
    secret_signing = _tencent_hmac(secret_service, "tc3_request")
    signature = hmac.new(secret_signing, string_to_sign.encode("utf-8"),
                         hashlib.sha256).hexdigest()
    authorization = ("TC3-HMAC-SHA256 Credential=%s/%s/sms/tc3_request, "
                     "SignedHeaders=%s, Signature=%s") % (
        cfg["secret_id"], date, signed_headers, signature)
    headers = {
        "Authorization": authorization,
        "Content-Type": content_type,
        "Host": host,
        "X-TC-Action": action,
        "X-TC-Timestamp": str(ts),
        "X-TC-Version": version,
        "X-TC-Region": region,
    }
    try:
        req = urllib.request.Request(endpoint, data=payload.encode("utf-8"),
                                     headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=8) as r:
            data = json.loads(r.read().decode("utf-8"))
        resp = data.get("Response") or {}
        status = (resp.get("SendStatusSet") or [{}])[0]
        if status.get("Code") == "Ok":
            return True, ""
        msg = status.get("Message") or resp.get("Error") or "unknown"
        return False, "sms_provider:" + str(msg)[:100]
    except Exception as e:
        return False, "sms_unreachable:" + str(e)[:100]


def send_sms_code(phone, code):
    cfg = sms_config()
    if not cfg:
        return False, "sms_not_configured"
    if cfg.get("provider") == "tencent":
        return send_tencent_sms(phone, code)
    if cfg.get("provider") == "spug":
        return send_spug_sms(phone, code)
    if cfg.get("provider") == "aliyun":
        return send_aliyun_sms(phone, code)
    return False, "sms_not_configured"


def _spug_sms_url(cfg):
    """返回 Spug 接口 URL；只允许官方 /sms/ 与 /send/，避免配置被改写后打内网。"""
    raw_url = str(cfg.get("spug_url") or "").strip()
    if raw_url:
        if not (raw_url.startswith(SPUG_SMS_BASE) or raw_url.startswith(SPUG_SEND_BASE)):
            return ""
        return raw_url
    code = str(cfg.get("spug_template_code") or "").strip()
    if not code:
        return ""
    return SPUG_SMS_BASE + urllib.parse.quote(code, safe="")


def _spug_payload(cfg, url, phone, code):
    """构造 Spug 请求体：/sms/ 用 to+code；/send/ 用消息模板变量。"""
    if "/sms/" in url:
        payload = {"to": str(phone), "code": str(code)}
        number = str(cfg.get("spug_number") or "").strip()
        if number:
            payload["number"] = number
        return payload
    mapping = cfg.get("spug_payload")
    if not isinstance(mapping, dict) or not mapping:
        mapping = {
            "name": str(cfg.get("spug_name") or "流萤社区"),
            "code": "{code}",
            "number": str(cfg.get("spug_number") or "5"),
            "targets": "{phone}",
        }
    name = str(cfg.get("spug_name") or "流萤社区")
    number = str(cfg.get("spug_number") or "5")
    payload = {}
    for key, value in mapping.items():
        text = str(value)
        text = text.replace("{phone}", str(phone)).replace("{code}", str(code))
        text = text.replace("{name}", name).replace("{number}", number)
        payload[str(key)] = text
    return payload


def send_spug_sms(phone, code):
    """Spug 推送助手共享模板：平台官方验证码模板，不需要企业签名报备。"""
    cfg = sms_config()
    if not cfg or cfg.get("provider") != "spug":
        return False, "sms_not_configured"
    url = _spug_sms_url(cfg)
    if not url:
        return False, "sms_not_configured"
    payload = json.dumps(_spug_payload(cfg, url, phone, code),
                         ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    try:
        req = urllib.request.Request(
            url,
            data=payload,
            headers={
                "Content-Type": "application/json",
                "User-Agent": "liuying-community/1.0",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=8) as r:
            raw = r.read().decode("utf-8", "replace")
        data = json.loads(raw)
        if str(data.get("code")) == "200":
            # Spug 返回 200 只表示已受理；真实送达看 request_id/发送记录。
            return True, ""
        msg = data.get("msg") or data.get("message") or "unknown"
        return False, "sms_provider:" + str(msg)[:100]
    except urllib.error.HTTPError as e:
        try:
            data = json.loads(e.read().decode("utf-8", "replace"))
            msg = data.get("msg") or data.get("message") or ("HTTP %s" % e.code)
        except Exception:
            msg = "HTTP %s" % e.code
        return False, "sms_provider:" + str(msg)[:100]
    except Exception as e:
        return False, "sms_unreachable:" + str(e)[:100]


def _pe(v):
    return urllib.parse.quote(str(v), safe="~")


def send_aliyun_sms(phone, code):
    cfg = sms_config()
    if not cfg:
        return False, "sms_not_configured"
    params = {
        "AccessKeyId": str(cfg["access_key_id"]),
        "Action": "SendSms",
        "Format": "JSON",
        "PhoneNumbers": phone,
        "RegionId": "cn-hangzhou",
        "SignName": str(cfg["sign_name"]),
        "SignatureMethod": "HMAC-SHA1",
        "SignatureNonce": secrets.token_hex(16),
        "SignatureVersion": "1.0",
        "TemplateCode": str(cfg["template_code"]),
        "TemplateParam": json.dumps({"code": code}, separators=(",", ":")),
        "Timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    canonical = "&".join("%s=%s" % (_pe(k), _pe(params[k])) for k in sorted(params))
    string_to_sign = "GET&%2F&" + _pe(canonical)
    sig = base64.b64encode(hmac.new((str(cfg["access_key_secret"]) + "&").encode(),
                                    string_to_sign.encode(), hashlib.sha1).digest()).decode()
    params["Signature"] = sig
    url = "https://dysmsapi.aliyuncs.com/?" + urllib.parse.urlencode(params)
    try:
        with urllib.request.urlopen(url, timeout=8) as r:
            data = json.loads(r.read().decode("utf-8"))
        if data.get("Code") == "OK":
            return True, ""
        return False, "sms_provider:" + str(data.get("Code") or "unknown")[:80]
    except Exception as e:
        return False, "sms_unreachable:" + str(e)[:100]


def send_phone_code(c, uid, phone, ip=""):
    p = normalize_phone(phone)
    if not PHONE_RE.match(p):
        return False, "invalid_phone"
    ph = phone_hash(p)
    # 一个手机号只能绑一个账号
    other = c.execute("SELECT user_id FROM community_invite_profiles "
                      "WHERE phone_hash=? AND user_id<>?", (ph, uid)).fetchone()
    if not other:
        other = c.execute("SELECT user_id FROM community_phone_accounts "
                          "WHERE phone_hash=? AND user_id<>?", (ph, uid)).fetchone()
    if other:
        return False, "phone_in_use"
    row = c.execute("SELECT created, attempts FROM community_invite_phone_codes "
                    "WHERE phone_hash=?", (ph,)).fetchone()
    if row and time.time() - (row[0] or 0) < 60:
        return False, "too_frequent"
    day = time.time() - 86400
    count = c.execute("SELECT COUNT(*) FROM community_invite_phone_log "
                      "WHERE phone_hash=? AND created>=?", (ph, day)).fetchone()[0]
    if count >= 5:
        return False, "daily_limit"
    code = "%06d" % secrets.randbelow(1000000)
    now = time.time()
    c.execute("INSERT INTO community_invite_phone_log(id,phone_hash,ip,created) VALUES(?,?,?,?)",
              (uuid.uuid4().hex, ph, ip[:64], now))
    c.execute("INSERT INTO community_invite_phone_codes(phone_hash,code_hash,created,expires,attempts,ip)"
              " VALUES(?,?,?,?,0,?) ON CONFLICT(phone_hash) DO UPDATE SET "
              "code_hash=excluded.code_hash,created=excluded.created,expires=excluded.expires,"
              "attempts=0,ip=excluded.ip",
              (ph, _code_hash(ph, code), now, now + 300, ip[:64]))
    ok, err = send_sms_code(p, code)
    if not ok:
        c.execute("DELETE FROM community_invite_phone_codes WHERE phone_hash=?", (ph,))
    c.commit()
    return ok, err


def _code_hash(ph, code):
    return hashlib.sha256((ph + ":" + code + ":liuying").encode()).hexdigest()


def confirm_phone(c, uid, phone, code, ip=""):
    p = normalize_phone(phone)
    if not PHONE_RE.match(p):
        return False, "invalid_phone"
    ph = phone_hash(p)
    row = c.execute("SELECT code_hash,expires,attempts FROM community_invite_phone_codes "
                    "WHERE phone_hash=?", (ph,)).fetchone()
    if not row:
        return False, "code_not_found"
    if time.time() > (row[1] or 0):
        return False, "code_expired"
    if int(row[2] or 0) >= 5:
        return False, "too_many_attempts"
    if not hmac.compare_digest(row[0], _code_hash(ph, str(code).strip())):
        c.execute("UPDATE community_invite_phone_codes SET attempts=attempts+1 WHERE phone_hash=?", (ph,))
        c.commit()
        return False, "code_error"
    other = c.execute("SELECT user_id FROM community_invite_profiles "
                      "WHERE phone_hash=? AND user_id<>?", (ph, uid)).fetchone()
    if not other:
        other = c.execute("SELECT user_id FROM community_phone_accounts "
                          "WHERE phone_hash=? AND user_id<>?", (ph, uid)).fetchone()
    if other:
        return False, "phone_in_use"
    now = time.time()
    ensure_profile(c, uid)
    c.execute("UPDATE community_invite_profiles SET phone_hash=?, phone_mask=?, phone_verified_at=?, "
              "updated=? WHERE user_id=?", (ph, mask_phone(p), now, now, uid))
    c.execute("DELETE FROM community_phone_accounts WHERE user_id=? AND phone_hash<>?", (uid, ph))
    c.execute("INSERT INTO community_phone_accounts(phone_hash,phone_mask,user_id,created,verified_at) "
              "VALUES(?,?,?,?,?) ON CONFLICT(phone_hash) DO UPDATE SET "
              "user_id=excluded.user_id,verified_at=excluded.verified_at",
              (ph, mask_phone(p), uid, now, now))
    b = c.execute("SELECT phone_hash,phone_mask FROM community_invite_bindings WHERE invitee_id=?",
                  (uid,)).fetchone()
    if b:
        c.execute("UPDATE community_invite_bindings SET phone_hash=?, phone_mask=? WHERE invitee_id=?",
                  (ph, mask_phone(p), uid))
    c.execute("DELETE FROM community_invite_phone_codes WHERE phone_hash=?", (ph,))
    c.commit()
    valid = mark_valid(c, uid)
    return True, {"phone": mask_phone(p), "valid": valid or {}}


def credit_membership(c, buyer_id, order_id, price_cents):
    """会员首单支付成功后，给邀请人 20% 实付返佣。只返一次。"""
    b = c.execute("SELECT id,inviter_id,status,commission_cents FROM community_invite_bindings "
                  "WHERE invitee_id=?", (buyer_id,)).fetchone()
    if not b or b[2] != "valid":
        return None
    bid, inviter, _, already = b
    if already and int(already) > 0:
        return None
    bps = int(get_setting(c, "commission_bps", "2000") or 2000)
    amount = max(0, int(price_cents or 0)) * bps // 10000
    if amount <= 0:
        return None
    days = int(get_setting(c, "settle_days", "7") or 7)
    now = time.time()
    add_ledger(c, inviter, "commission", amount, order_id, "frozen",
               now + days * 86400, "会员首单 %d%% 返佣" % (bps // 100))
    c.execute("UPDATE community_invite_bindings SET commission_cents=?, first_order_id=? WHERE id=?",
              (amount, order_id, bid))
    c.commit()
    return amount


def user_snapshot(c, uid, email=""):
    ensure_profile(c, uid)
    p = profile(c, uid)
    bal = balance_state(c, uid)
    cap_used, cap = _monthly_fixed_used(c, uid)
    budget_used, budget = _monthly_budget_used(c)
    pending = c.execute("SELECT COUNT(*) FROM community_invite_bindings "
                        "WHERE inviter_id=? AND status='pending'", (uid,)).fetchone()[0]
    valid = c.execute("SELECT COUNT(*) FROM community_invite_bindings "
                      "WHERE inviter_id=? AND status='valid'", (uid,)).fetchone()[0]
    rows = c.execute(
        "SELECT b.status,b.created,b.reward_cents,b.commission_cents,"
        " COALESCE(u.email,''), COALESCE(u.name,''), b.phone_mask "
        "FROM community_invite_bindings b LEFT JOIN users u ON u.id=b.invitee_id "
        "WHERE b.inviter_id=? ORDER BY b.created DESC LIMIT 50", (uid,)).fetchall()
    invitees = []
    for st, created, reward, comm, mail, name, pmask in rows:
        invitees.append({
            "name": name or "新朋友",
            "email": mask_email(mail),
            "phone": pmask or "",
            "status": st,
            "reward_yuan": round((reward or 0) / 100, 2),
            "commission_yuan": round((comm or 0) / 100, 2),
            "created": created,
        })
    wds = c.execute("SELECT id,amount_cents,status,created,admin_note FROM community_invite_withdrawals "
                    "WHERE user_id=? ORDER BY created DESC LIMIT 20", (uid,)).fetchall()
    withdraws = [{"id": r[0], "amount_yuan": round((r[1] or 0) / 100, 2),
                  "status": r[2], "created": r[3], "note": r[4]} for r in wds]
    bind = c.execute("SELECT status,inviter_id,reward_cents,commission_cents FROM community_invite_bindings "
                     "WHERE invitee_id=? ORDER BY created DESC LIMIT 1", (uid,)).fetchone()
    binding = None
    if bind:
        binding = {"status": bind[0], "inviter_id": bind[1],
                   "reward_yuan": round((bind[2] or 0) / 100, 2),
                   "commission_yuan": round((bind[3] or 0) / 100, 2)}
    share_count = c.execute("SELECT COUNT(*) FROM community_invite_shares WHERE inviter_id=?",
                            (uid,)).fetchone()[0]
    urow = c.execute("SELECT COALESCE(name,''), COALESCE(account,'') FROM users WHERE id=?",
                     (uid,)).fetchone()
    return {
        "name": (urow[0] if urow else "") or "流萤用户",
        "account": (urow[1] if urow else "") or "",
        "code": p[1],
        "link": invite_url(p[1]),
        "phone": p[3] or "",
        "phone_verified": bool(p[4]),
        "phone_mask": p[3] or "",
        "clicks": p[5] or 0,
        "share_count": share_count,
        "valid_count": valid,
        "pending_count": pending,
        "cap": cap,
        "cap_used": cap_used,
        "budget": round(budget / 100, 2),
        "budget_used": round(budget_used / 100, 2),
        "available_yuan": round(bal["available_cents"] / 100, 2),
        "frozen_yuan": round(bal["frozen_cents"] / 100, 2),
        "earned_yuan": round(bal["earned_cents"] / 100, 2),
        "withdrawn_yuan": round(bal["withdrawn_cents"] / 100, 2),
        "min_withdraw_yuan": round(int(get_setting(c, "min_withdraw_cents", "1000") or 1000) / 100, 2),
        "invitees": invitees,
        "withdrawals": withdraws,
        "binding": binding,
    }


def public_info(c):
    return {
        "enabled": get_setting(c, "enabled", "1") == "1",
        "fixed_reward_yuan": round(int(get_setting(c, "fixed_reward_cents", "100") or 100) / 100, 2),
        "commission_percent": int(get_setting(c, "commission_bps", "2000") or 2000) / 100,
        "min_withdraw_yuan": round(int(get_setting(c, "min_withdraw_cents", "1000") or 1000) / 100, 2),
        "settle_days": int(get_setting(c, "settle_days", "7") or 7),
        "monthly_invite_cap": int(get_setting(c, "monthly_invite_cap", "30") or 30),
        "rule_version": get_setting(c, "rule_version", "2026-11-21"),
        "download_ios": get_setting(c, "download_ios"),
        "download_android": get_setting(c, "download_android"),
    }


def save_qr(uid, data_url):
    raw = str(data_url or "")
    if "," in raw and raw.strip().lower().startswith("data:"):
        raw = raw.split(",", 1)[1]
    try:
        b = base64.b64decode(raw)
    except Exception:
        return None, "bad_image"
    if len(b) > 3 * 1024 * 1024:
        return None, "image_too_large"
    try:
        from PIL import Image
        im = Image.open(io.BytesIO(b))
        im.verify()
        im = Image.open(io.BytesIO(b)).convert("RGB")
    except Exception:
        return None, "bad_image"
    d = os.path.join(_qr_dir(), uid)
    os.makedirs(d, exist_ok=True)
    name = uuid.uuid4().hex + ".jpg"
    path = os.path.join(d, name)
    im.save(path, "JPEG", quality=88)
    return path, ""


def request_withdraw(c, uid, amount_cents, name, phone, qr_data):
    p = normalize_phone(phone)
    if not PHONE_RE.match(p):
        return False, "invalid_phone"
    if not (2 <= len(str(name).strip()) <= 30):
        return False, "invalid_name"
    amount = int(amount_cents or 0)
    mn = int(get_setting(c, "min_withdraw_cents", "1000") or 1000)
    if amount < mn:
        return False, "below_min"
    pp = profile(c, uid)
    if not pp or not pp[4]:
        return False, "phone_not_verified"
    if c.execute("SELECT 1 FROM community_invite_withdrawals WHERE user_id=? "
                 "AND status IN ('pending','approved')", (uid,)).fetchone():
        return False, "pending_exists"
    bal = balance_state(c, uid)
    if amount > bal["available_cents"]:
        return False, "insufficient"
    path, err = save_qr(uid, qr_data)
    if err:
        return False, err
    now = time.time()
    wid = uuid.uuid4().hex
    c.execute("INSERT INTO community_invite_withdrawals"
              "(id,user_id,amount_cents,name,phone,qr_path,status,created)"
              " VALUES(?,?,?,?,?,?, 'pending', ?)",
              (wid, uid, amount, str(name).strip()[:30], p, path, now))
    add_ledger(c, uid, "withdraw", -amount, wid, "pending", 0, "提现申请")
    c.commit()
    return True, {"id": wid, "amount_yuan": round(amount / 100, 2)}
