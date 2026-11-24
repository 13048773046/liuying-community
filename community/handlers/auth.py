# -*- coding: utf-8 -*-
"""社区登录/注册兜底：音乐服务停掉时，账号密码与邮箱验证码都可在社区完成。

这不是第二套账号体系：
- 账号、密码哈希、tokens、email_codes 都沿用音乐共享库，token 互通；
- `/auth/login` 处理账号密码；`/auth/send-email-code` + `/auth/login-email`
  处理邮箱验证码，新邮箱自动注册、老邮箱直接登录；
- 音乐恢复后客户端优先走音乐接口，失败再回退社区。
"""
import hashlib
import hmac
import json
import os
import re
import secrets
import time
import uuid

from common import db, public_user, client_ip, rate_limit, rate_limit_key, invalidate_token
from core.security import constant_time_eq, otp_hash
import invite_core
import captcha

TOKEN_TTL = 15 * 86400
PASSWORD_ITER = 210000
LEGACY_ITER = 120000
LOGIN_MAX_FAIL = 5
LOGIN_LOCK_SECONDS = 900


def _otp() -> str:
    """密码学安全 6 位验证码，禁止 random.randint。"""
    return "%06d" % secrets.randbelow(1000000)


def _account_key(account: str) -> str:
    return hashlib.sha256(str(account or "").strip().lower().encode("utf-8")).hexdigest()[:32]


def _body(h):
    return h._json_body() or {}


def _verify_password(pw, stored):
    """与音乐 server/common.py 的 verify_password 完全兼容（v2 + v1）。"""
    try:
        parts = (stored or "").split("$")
        if len(parts) == 3:
            salt, iters_s, expected = parts
            iters = int(iters_s)
        elif len(parts) == 2:
            salt, expected = parts
            iters = LEGACY_ITER
        else:
            return False
        if iters <= 0 or iters > 10_000_000:
            return False
        test = hashlib.pbkdf2_hmac(
            "sha256", pw.encode("utf-8"), bytes.fromhex(salt), iters).hex()
        return hmac.compare_digest(expected, test)
    except Exception:
        return False


def _hash_password(pw):
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac(
        "sha256", pw.encode("utf-8"), bytes.fromhex(salt), PASSWORD_ITER).hex()
    return "%s$%d$%s" % (salt, PASSWORD_ITER, digest)


def _legacy_hash(stored):
    return isinstance(stored, str) and len(stored.split("$")) == 2


def _ensure_email_codes(c):
    c.execute("""CREATE TABLE IF NOT EXISTS email_codes(
        email TEXT PRIMARY KEY, code TEXT NOT NULL,
        created REAL NOT NULL, last_sent REAL NOT NULL,
        fail_count INTEGER DEFAULT 0, day_count INTEGER DEFAULT 0,
        day_date TEXT DEFAULT '')""")
    c.execute("""CREATE TABLE IF NOT EXISTS community_auth_locks(
        scope TEXT NOT NULL, subject TEXT NOT NULL,
        fails INTEGER DEFAULT 0, first_at REAL DEFAULT 0,
        locked_until REAL DEFAULT 0,
        PRIMARY KEY(scope,subject))""")


def _lock_remaining(c, scope, subject, now=None):
    _ensure_email_codes(c)
    now = time.time() if now is None else now
    row = c.execute("SELECT locked_until,fails,first_at FROM community_auth_locks "
                    "WHERE scope=? AND subject=?", (scope, subject)).fetchone()
    if not row:
        return 0
    if (row[0] or 0) > now:
        return int(row[0] - now)
    # 锁定窗口结束或首击已过期，重置计数；保留行避免频繁增删。
    if (row[2] or 0) < now - LOGIN_LOCK_SECONDS and not (row[0] or 0):
        c.execute("DELETE FROM community_auth_locks WHERE scope=? AND subject=?",
                  (scope, subject))
        c.commit()
    return 0


def _record_auth_failure(c, scope, subject):
    _ensure_email_codes(c)
    now = time.time()
    row = c.execute("SELECT fails,first_at,locked_until FROM community_auth_locks "
                    "WHERE scope=? AND subject=?", (scope, subject)).fetchone()
    if not row or (row[1] or 0) < now - LOGIN_LOCK_SECONDS:
        fails, first_at, locked_until = 1, now, 0
    else:
        fails, first_at, locked_until = int(row[0] or 0) + 1, row[1], row[2] or 0
    if fails >= LOGIN_MAX_FAIL:
        locked_until = now + LOGIN_LOCK_SECONDS
    c.execute("INSERT INTO community_auth_locks(scope,subject,fails,first_at,locked_until) "
              "VALUES(?,?,?,?,?) ON CONFLICT(scope,subject) DO UPDATE SET "
              "fails=excluded.fails,first_at=excluded.first_at,locked_until=excluded.locked_until",
              (scope, subject, fails, first_at, locked_until))
    c.commit()
    return locked_until > now


def _clear_auth_failure(c, scope, subject):
    try:
        c.execute("DELETE FROM community_auth_locks WHERE scope=? AND subject=?",
                  (scope, subject))
        c.commit()
    except Exception:
        pass


PHONE_RE = re.compile(r"^1[3-9]\d{9}$")
PHONE_LOGIN_TABLE = "community_phone_accounts"


def _clean_identifier(raw):
    s = str(raw or "").strip()
    out = []
    for ch in s:
        code = ord(ch)
        if 0xFF10 <= code <= 0xFF19:
            out.append(chr(code - 0xFEE0))
        elif ch in (" ", "-", "(", ")", "\u3000"):
            continue
        elif ch in ("＋", "＠", "．", "－"):
            out.append({ "＋":"+", "＠":"@", "．":".", "－":"-" }[ch])
        else:
            out.append(ch)
    s = "".join(out)
    if s.startswith("+86"):
        s = s[3:]
    elif s.startswith("86") and len(s) == 13:
        s = s[2:]
    return s


def detect_identifier(raw):
    """单输入框识别：返回 (kind, value) 或 (None, '')。"""
    s = _clean_identifier(raw)
    if re.match(r"^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+$", s):
        return "email", s.lower()
    if PHONE_RE.match(s):
        return "phone", s
    return None, ""


def _ensure_phone_auth(c):
    c.execute("""CREATE TABLE IF NOT EXISTS community_phone_accounts(
        phone_hash TEXT PRIMARY KEY,
        phone_mask TEXT DEFAULT '',
        user_id TEXT NOT NULL UNIQUE,
        created REAL,
        verified_at REAL
    )""")
    c.execute("""CREATE TABLE IF NOT EXISTS community_phone_codes(
        phone_hash TEXT PRIMARY KEY,
        code_hash TEXT NOT NULL,
        created REAL NOT NULL,
        expires REAL NOT NULL,
        attempts INTEGER DEFAULT 0,
        ip TEXT DEFAULT ''
    )""")
    c.execute("""CREATE TABLE IF NOT EXISTS community_phone_send_log(
        id TEXT PRIMARY KEY,
        phone_hash TEXT NOT NULL,
        ip TEXT DEFAULT '',
        created REAL
    )""")


def _phone_hash(phone):
    return invite_core.phone_hash(phone)


def _phone_mask(phone):
    return invite_core.mask_phone(phone)


def _phone_code_hash(phone_hash, code):
    return otp_hash("phone:" + phone_hash, str(code))


def _legacy_phone_code_hash(phone_hash, code):
    return hashlib.sha256((phone_hash + ":" + str(code) + ":auth-code").encode()).hexdigest()


def _phone_account(c, phone_hash):
    _ensure_phone_auth(c)
    row = c.execute("SELECT user_id FROM community_phone_accounts WHERE phone_hash=?",
                    (phone_hash,)).fetchone()
    if row:
        return row[0]
    # 兼容已经通过邀请流程验证过手机号的老账号
    row = c.execute("SELECT user_id,phone_mask FROM community_invite_profiles WHERE phone_hash=?",
                    (phone_hash,)).fetchone()
    if row:
        c.execute("INSERT OR IGNORE INTO community_phone_accounts"
                  "(phone_hash,phone_mask,user_id,created,verified_at) VALUES(?,?,?,?,?)",
                  (phone_hash, row[1] or "", row[0], time.time(), time.time()))
        return row[0]
    return None


def _sync_phone_profile(c, uid, phone, phone_hash):
    """手机号登录本身就是所有权证明，同步到邀请资料；有 pending 绑定就转有效。"""
    try:
        invite_core.ensure_profile(c, uid)
        now = time.time()
        c.execute("UPDATE community_invite_profiles SET phone_hash=?, phone_mask=?, "
                  "phone_verified_at=?, updated=? WHERE user_id=?",
                  (phone_hash, _phone_mask(phone), now, now, uid))
        b = c.execute("SELECT id FROM community_invite_bindings WHERE invitee_id=?",
                      (uid,)).fetchone()
        if b:
            c.execute("UPDATE community_invite_bindings SET phone_hash=?, phone_mask=? "
                      "WHERE invitee_id=?", (phone_hash, _phone_mask(phone), uid))
            c.commit()
            invite_core.mark_valid(c, uid)
        else:
            c.commit()
    except Exception:
        try:
            c.rollback()
        except Exception:
            pass


def _send_phone_login_code(self, c, phone, body=None):
    _ensure_phone_auth(c)
    if not captcha.require(self, c, body or {}):
        return True
    ph = _phone_hash(phone)
    now = time.time()
    if not rate_limit_key(self, "phone_send_subject", _account_key(ph), 3, 600):
        self._err(429, "这个手机号发送过于频繁，请稍后再试")
        return True
    row = c.execute("SELECT created FROM community_phone_codes WHERE phone_hash=?",
                    (ph,)).fetchone()
    if row and now - (row[0] or 0) < 60:
        self._err(429, "验证码 60 秒内只能发一次")
        return True
    day = now - 86400
    cnt = c.execute("SELECT COUNT(*) FROM community_phone_send_log "
                    "WHERE phone_hash=? AND created>=?", (ph, day)).fetchone()[0]
    if cnt >= 5:
        self._err(429, "这个手机号今天发送次数已达上限")
        return True
    code = _otp()
    c.execute("INSERT INTO community_phone_send_log(id,phone_hash,ip,created) VALUES(?,?,?,?)",
              (uuid.uuid4().hex, ph, client_ip(self)[:64], now))
    c.execute("INSERT INTO community_phone_codes(phone_hash,code_hash,created,expires,attempts,ip) "
              "VALUES(?,?,?,?,0,?) ON CONFLICT(phone_hash) DO UPDATE SET "
              "code_hash=excluded.code_hash,created=excluded.created,expires=excluded.expires,"
              "attempts=0,ip=excluded.ip",
              (ph, _phone_code_hash(ph, code), now, now + 300, client_ip(self)[:64]))
    ok, err = invite_core.send_sms_code(phone, code)
    if not ok:
        c.execute("DELETE FROM community_phone_codes WHERE phone_hash=?", (ph,))
    c.commit()
    if not ok:
        msg = "短信通道还没配置，请稍后再试" if err == "sms_not_configured" else "验证码发送失败，请稍后再试"
        self._err(503 if err == "sms_not_configured" else 502, msg)
        return True
    # 不暴露手机号是否已注册
    self._send(200, {"ok": True, "channel": "phone", "expires": 300})
    return True


def _login_phone(self, c, phone, code):
    _ensure_phone_auth(c)
    ph = _phone_hash(phone)
    now = time.time()
    lock_subject = _account_key("phone:" + ph)
    left = _lock_remaining(c, "phone_login", lock_subject, now)
    if left:
        self._err(429, "验证码错误次数过多，请 %d 分钟后再试" % max(1, left // 60))
        return True
    row = c.execute("SELECT code_hash,expires,attempts FROM community_phone_codes "
                    "WHERE phone_hash=?", (ph,)).fetchone()
    if not row:
        self._err(400, "验证码错误或已过期")
        return True
    if now > (row[1] or 0):
        self._err(400, "验证码已过期，请重新获取")
        return True
    if int(row[2] or 0) >= 5:
        self._err(429, "验证码错误次数过多，请重新获取")
        return True
    submitted = str(code or "").strip()
    if not (constant_time_eq(row[0], _phone_code_hash(ph, submitted)) or
            constant_time_eq(row[0], _legacy_phone_code_hash(ph, submitted))):
        c.execute("UPDATE community_phone_codes SET attempts=attempts+1 WHERE phone_hash=?", (ph,))
        c.commit()
        _record_auth_failure(c, "phone_login", lock_subject)
        self._err(400, "验证码错误")
        return True
    _clear_auth_failure(c, "phone_login", lock_subject)
    uid = _phone_account(c, ph)
    if not uid:
        uid = uuid.uuid4().hex
        account = ""
        for _ in range(50):
            cand = str(secrets.randbelow(900000) + 100000)
            if not c.execute("SELECT 1 FROM users WHERE account=?", (cand,)).fetchone():
                account = cand
                break
        if not account:
            self._err(500, "账号生成失败，请重试")
            return True
        c.execute("INSERT INTO users(id,account,password_hash,name,avatar,created,email,ip_address) "
                  "VALUES(?,?,?,?,?,?,?,?)",
                  (uid, account, "", "用户" + account, "", now, "", client_ip(self)))
        c.execute("INSERT INTO community_phone_accounts(phone_hash,phone_mask,user_id,created,verified_at) "
                  "VALUES(?,?,?,?,?)", (ph, _phone_mask(phone), uid, now, now))
    else:
        banned = c.execute("SELECT banned,ban_reason FROM users WHERE id=?", (uid,)).fetchone()
        if banned and banned[0]:
            self._err(403, "账号已被封禁：" + (banned[1] or "联系管理员"))
            return True
        c.execute("DELETE FROM community_phone_accounts WHERE user_id=? AND phone_hash<>?",
                  (uid, ph))
        c.execute("INSERT INTO community_phone_accounts(phone_hash,phone_mask,user_id,created,verified_at) "
                  "VALUES(?,?,?,?,?) ON CONFLICT(phone_hash) DO UPDATE SET "
                  "user_id=excluded.user_id,verified_at=excluded.verified_at",
                  (ph, _phone_mask(phone), uid, now, now))
    c.execute("DELETE FROM community_phone_codes WHERE phone_hash=?", (ph,))
    c.commit()
    _sync_phone_profile(c, uid, phone, ph)
    token = _issue_token(c, uid)
    out = public_user(c, uid, uid) or {}
    out["token"] = token
    out["login_channel"] = "phone"
    out["phone_mask"] = _phone_mask(phone)
    self._send(200, out)
    return True


def _smtp_config():
    """优先读中立配置，回退音乐配置；环境变量可覆盖。"""
    path = os.environ.get("COMMUNITY_SMTP_CONFIG",
                          "/www/wwwroot/yosar-data/config/smtp.json")
    cfg = {}
    for p in (path, "/www/wwwroot/music/config.json"):
        if not p or not os.path.exists(p):
            continue
        try:
            with open(p, "r", encoding="utf-8") as f:
                loaded = json.load(f)
            if isinstance(loaded, dict):
                cfg.update(loaded)
                break
        except Exception:
            continue
    for key, env in (
        ("smtp_host", "COMMUNITY_SMTP_HOST"),
        ("smtp_port", "COMMUNITY_SMTP_PORT"),
        ("smtp_user", "COMMUNITY_SMTP_USER"),
        ("smtp_pass", "COMMUNITY_SMTP_PASS"),
        ("smtp_from_name", "COMMUNITY_SMTP_FROM_NAME"),
    ):
        if os.environ.get(env):
            cfg[key] = os.environ[env]
    return cfg


def _send_email_code(email, code, cfg):
    import smtplib
    from email.mime.text import MIMEText
    from email.header import Header
    from email.utils import formataddr

    host = str(cfg.get("smtp_host") or "").strip()
    user = str(cfg.get("smtp_user") or "").strip()
    password = str(cfg.get("smtp_pass") or "")
    if not host or not user or not password:
        raise RuntimeError("not_configured")
    try:
        port = int(cfg.get("smtp_port") or 465)
    except Exception:
        port = 465
    from_name = str(cfg.get("smtp_from_name") or "流萤社区")
    msg = MIMEText(
        "您的验证码是：%s\n\n验证码 5 分钟内有效，请勿泄露给他人。" % code,
        "plain", "utf-8")
    msg["From"] = formataddr((str(Header(from_name, "utf-8")), user))
    msg["To"] = email
    msg["Subject"] = Header("流萤社区 · 邮箱验证码", "utf-8")
    if port == 465:
        server = smtplib.SMTP_SSL(host, port, timeout=10)
    else:
        server = smtplib.SMTP(host, port, timeout=10)
        server.starttls()
    try:
        server.login(user, password)
        server.sendmail(user, [email], msg.as_string())
    finally:
        try:
            server.quit()
        except Exception:
            pass


def _issue_token(c, uid):
    token = secrets.token_urlsafe(32)
    now = time.time()
    c.execute("INSERT INTO tokens(token,user_id,created,expires) VALUES(?,?,?,?)",
              (token, uid, now, now + TOKEN_TTL))
    return token


def _send_code(self, c, body):
    email = (body.get("email") or "").strip().lower()
    if not re.match(r"^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+$", email):
        self._err(400, "邮箱格式不正确")
        return True
    if not captcha.require(self, c, body):
        return True
    if not rate_limit(self, "send_email"):
        self._err(429, "发送过于频繁，请稍后再试")
        return True
    if not rate_limit_key(self, "email_send_subject", _account_key(email), 3, 600):
        self._err(429, "该邮箱发送过于频繁，请稍后再试")
        return True
    cfg = _smtp_config()
    if not (str(cfg.get("smtp_host") or "").strip()
            and str(cfg.get("smtp_user") or "").strip()
            and str(cfg.get("smtp_pass") or "")):
        self._err(503, "邮箱服务未配置")
        return True
    _ensure_email_codes(c)
    now = time.time()
    resend = int(os.environ.get("COMMUNITY_EMAIL_CODE_RESEND", "60") or 60)
    daily = int(os.environ.get("COMMUNITY_EMAIL_CODE_DAILY", "5") or 5)
    row = c.execute("SELECT last_sent, day_count, day_date FROM email_codes WHERE email=?",
                    (email,)).fetchone()
    if row and (now - row[0]) < resend:
        self._err(429, "请 %d 秒后再试" % max(1, int(resend - (now - row[0]))) )
        return True
    today = time.strftime("%Y-%m-%d")
    day_cnt = (row[1] or 0) if row and row[2] == today else 0
    if day_cnt >= daily:
        self._err(429, "该邮箱今日发送次数已达上限，请明天再试")
        return True
    code = _otp()
    try:
        _send_email_code(email, code, cfg)
    except RuntimeError:
        self._err(503, "邮箱服务未配置")
        return True
    except Exception:
        self._err(500, "邮件发送失败，请稍后再试")
        return True
    # 只落 HMAC；数据库泄露也不能直接登录。
    stored = "h1$" + otp_hash("email:" + email, code)
    c.execute("""INSERT OR REPLACE INTO email_codes
                 (email, code, created, last_sent, fail_count, day_count, day_date)
                 VALUES(?,?,?,?,?,?,?)""",
              (email, stored, now, now, 0, day_cnt + 1, today))
    c.commit()
    self._send(200, {"ok": True})
    return True


def _login_email(self, c, body):
    email = (body.get("email") or "").strip().lower()
    code = (body.get("code") or "").strip()
    if not email or not code:
        self._err(400, "请输入邮箱和验证码")
        return True
    if not rate_limit(self, "login_email"):
        self._err(429, "尝试过于频繁，请稍后再试")
        return True
    lock_subject = _account_key("email:" + email)
    left = _lock_remaining(c, "email_login", lock_subject)
    if left:
        self._err(429, "验证码错误次数过多，请 %d 分钟后再试" % max(1, left // 60))
        return True
    cols = {r[1] for r in c.execute("PRAGMA table_info(users)").fetchall()}
    if "email" not in cols:
        self._err(503, "共享用户表缺少 email 列")
        return True
    _ensure_email_codes(c)
    row = c.execute("SELECT code, created, fail_count FROM email_codes WHERE email=?",
                    (email,)).fetchone()
    if not row:
        self._err(400, "验证码错误")
        return True
    max_fail = int(os.environ.get("COMMUNITY_EMAIL_CODE_MAX_FAIL", "5") or 5)
    expire = int(os.environ.get("COMMUNITY_EMAIL_CODE_EXPIRE", "300") or 300)
    stored = str(row[0] or "")
    if stored.startswith("h1$"):
        matched = constant_time_eq(stored[3:], otp_hash("email:" + email, code))
    else:
        # 兼容升级前已发出的明文验证码：本次校验成功后立刻迁移/删除。
        matched = constant_time_eq(stored, code)
    if not matched:
        fc = (row[2] or 0) + 1
        if fc >= max_fail:
            c.execute("DELETE FROM email_codes WHERE email=?", (email,))
        else:
            c.execute("UPDATE email_codes SET fail_count=? WHERE email=?", (fc, email))
        c.commit()
        _record_auth_failure(c, "email_login", lock_subject)
        self._err(400, "验证码错误")
        return True
    if (time.time() - row[1]) > expire:
        self._err(400, "验证码已过期，请重新获取")
        return True
    _clear_auth_failure(c, "email_login", lock_subject)
    select_cols = """id,account,password_hash,name,avatar,created,gender,age,
        background_image,signature,ip_address,city,title,verified,verified_label,
        member,member_expire,svip_expire"""
    user = c.execute("SELECT " + select_cols + " FROM users WHERE email=?", (email,)).fetchone()
    if not user:
        uid = uuid.uuid4().hex
        account = ""
        for _ in range(50):
            cand = str(secrets.randbelow(900000) + 100000)
            if not c.execute("SELECT 1 FROM users WHERE account=?", (cand,)).fetchone():
                account = cand
                break
        if not account:
            self._err(500, "账号生成失败，请重试")
            return True
        name = "用户" + account
        insert_cols = ["id", "account", "password_hash", "name", "avatar", "created",
                       "email", "ip_address"]
        insert_vals = [uid, account, "", name, "", time.time(), email, client_ip(self)]
        if "email_verified" in cols:
            insert_cols.append("email_verified")
            insert_vals.append(1)
        c.execute("INSERT INTO users(" + ",".join(insert_cols) + ") VALUES("
                  + ",".join(["?"] * len(insert_cols)) + ")", tuple(insert_vals))
        user = c.execute("SELECT " + select_cols + " FROM users WHERE id=?", (uid,)).fetchone()
    else:
        banned = c.execute("SELECT banned, ban_reason FROM users WHERE id=?", (user[0],)).fetchone()
        if banned and banned[0]:
            self._err(403, "账号已被封禁：" + (banned[1] or "联系管理员"))
            return True
    token = _issue_token(c, user[0])
    c.execute("DELETE FROM email_codes WHERE email=?", (email,))
    c.commit()
    out = public_user(c, user[0], user[0]) or {}
    out["token"] = token
    self._send(200, out)
    return True


def _find_user(c, account):
    cols = {r[1] for r in c.execute("PRAGMA table_info(users)").fetchall()}
    if "email" in cols:
        return c.execute(
            """SELECT id,password_hash,banned,ban_reason FROM users
               WHERE account=? OR lower(ifnull(email,''))=lower(?)
               ORDER BY (account=?) DESC LIMIT 1""",
            (account, account, account)).fetchone()
    return c.execute(
        """SELECT id,password_hash,banned,ban_reason FROM users
           WHERE account=? LIMIT 1""", (account,)).fetchone()


def _login(self, c, body):
    account = (body.get("account") or "").strip()
    password = body.get("password") or ""
    if not account or not password:
        self._err(400, "请输入账号和密码")
        return True
    if len(account) > 128 or len(password) > 128:
        self._err(400, "账号或密码格式不正确")
        return True
    if not rate_limit(self, "login"):
        self._err(429, "登录尝试过于频繁，请稍后再试")
        return True
    lock_subject = _account_key(account)
    left = _lock_remaining(c, "password_login", lock_subject)
    if left:
        self._err(429, "登录失败次数过多，请 %d 分钟后再试" % max(1, left // 60))
        return True
    row = _find_user(c, account)
    if not row or not _verify_password(password, row[1]):
        _record_auth_failure(c, "password_login", lock_subject)
        self._err(401, "账号或密码错误")
        return True
    if row[2]:
        self._err(403, "账号已被封禁：" + (row[3] or "联系管理员"))
        return True
    _clear_auth_failure(c, "password_login", lock_subject)
    uid = row[0]
    if _legacy_hash(row[1]):
        c.execute("UPDATE users SET password_hash=? WHERE id=?",
                  (_hash_password(password), uid))
    ip = client_ip(self)
    if ip:
        c.execute("UPDATE users SET ip_address=? WHERE id=?", (ip, uid))
    token = _issue_token(c, uid)
    c.commit()
    out = public_user(c, uid, uid) or {}
    out["token"] = token
    self._send(200, out)
    return True


def _logout(self, c, u):
    """服务端撤销当前 token；客户端同时清本地安全存储。"""
    auth = self.headers.get("Authorization", "") or ""
    tok = auth[7:].strip() if auth.lower().startswith("bearer ") else ""
    if tok:
        c.execute("DELETE FROM tokens WHERE token=?", (tok,))
        c.commit()
        invalidate_token(tok)
    self._send(200, {"ok": True})
    return True


def dispatch(self, c, u, api, method):
    if method != "POST":
        return False
    if api == "/auth/login":
        return _login(self, c, _body(self))
    if api == "/auth/send-code":
        b = _body(self)
        kind, ident = detect_identifier(b.get("identifier") or b.get("account") or "")
        if not kind:
            self._err(400, "请输入正确的手机号或邮箱")
            return True
        if not rate_limit(self, "send_login_code"):
            self._err(429, "发送过于频繁，请稍后再试")
            return True
        if kind == "email":
            # 保留 captcha_id / captcha_code，不能只把 email 传给 _send_code。
            payload = dict(b)
            payload["email"] = ident
            return _send_code(self, c, payload)
        return _send_phone_login_code(self, c, ident, b)

    if api == "/auth/login-code":
        b = _body(self)
        kind, ident = detect_identifier(b.get("identifier") or b.get("account") or "")
        if not kind:
            self._err(400, "请输入正确的手机号或邮箱")
            return True
        if not rate_limit(self, "login_code"):
            self._err(429, "尝试过于频繁，请稍后再试")
            return True
        if kind == "email":
            return _login_email(self, c, {"email": ident, "code": b.get("code")})
        return _login_phone(self, c, ident, b.get("code") or "")

    if api == "/auth/send-email-code":
        return _send_code(self, c, _body(self))
    if api == "/auth/login-email":
        return _login_email(self, c, _body(self))
    if api == "/auth/logout":
        return _logout(self, c, u)
    return False
