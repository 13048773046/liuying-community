# -*- coding: utf-8 -*-
"""客户端热更新配置：运行期可下发的维护模式 / 公告 / 功能开关 / 任意远程配置。

Android 与 iOS 共用同一套配置中心，可按平台、渠道、build 区间与灰度比例下发。
这里只做「配置与资源策略」热更新，不替换已签名的可执行代码。
"""
from __future__ import annotations

import hashlib
import json
import re
import time
import uuid
from datetime import datetime, timezone
from urllib.parse import parse_qs, urlparse

from common import row_dict

KEY_RE = re.compile(r"^[a-z][a-z0-9_.-]{1,63}$")
PLATFORMS = ("all", "android", "ios")
CHANNELS = ("all", "stable", "beta", "internal")
CATEGORIES = ("config", "flag", "notice", "maintenance", "copy", "experiment")
VALUE_TYPES = ("json", "bool", "string", "number")

MAX_VALUE_BYTES = 32 * 1024

_SCHEMA = """
CREATE TABLE IF NOT EXISTS community_app_hot_configs (
    id TEXT PRIMARY KEY,
    key TEXT NOT NULL,
    category TEXT NOT NULL DEFAULT 'config',
    platform TEXT NOT NULL DEFAULT 'all',
    channel TEXT NOT NULL DEFAULT 'all',
    value_type TEXT NOT NULL DEFAULT 'json',
    value_json TEXT NOT NULL DEFAULT '{}',
    description TEXT NOT NULL DEFAULT '',
    status INTEGER NOT NULL DEFAULT 0,
    priority INTEGER NOT NULL DEFAULT 0,
    min_build INTEGER NOT NULL DEFAULT 0,
    max_build INTEGER NOT NULL DEFAULT 0,
    rollout INTEGER NOT NULL DEFAULT 100,
    starts_at REAL NOT NULL DEFAULT 0,
    ends_at REAL NOT NULL DEFAULT 0,
    revision INTEGER NOT NULL DEFAULT 0,
    created REAL NOT NULL DEFAULT 0,
    updated REAL NOT NULL DEFAULT 0,
    published_at REAL NOT NULL DEFAULT 0,
    created_by TEXT NOT NULL DEFAULT ''
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_hot_scope
    ON community_app_hot_configs(platform, channel, key);
CREATE INDEX IF NOT EXISTS idx_hot_status
    ON community_app_hot_configs(status, platform, channel);
CREATE TABLE IF NOT EXISTS community_app_hot_revisions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    config_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    action TEXT NOT NULL DEFAULT 'save',
    snapshot_json TEXT NOT NULL DEFAULT '{}',
    admin TEXT NOT NULL DEFAULT '',
    created REAL NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_hot_rev_config
    ON community_app_hot_revisions(config_id, revision DESC);
CREATE TABLE IF NOT EXISTS community_app_hot_audit (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    action TEXT NOT NULL,
    config_id TEXT NOT NULL DEFAULT '',
    key TEXT NOT NULL DEFAULT '',
    admin TEXT NOT NULL DEFAULT '',
    detail TEXT NOT NULL DEFAULT '',
    created REAL NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_hot_audit_created
    ON community_app_hot_audit(created DESC);
CREATE TABLE IF NOT EXISTS community_app_hot_meta (
    k TEXT PRIMARY KEY,
    v TEXT NOT NULL DEFAULT ''
);
"""


def init_schema(c):
    c.executescript(_SCHEMA)
    c.execute(
        "INSERT OR IGNORE INTO community_app_hot_meta(k,v) VALUES('revision','0')"
    )
    c.execute(
        "INSERT OR IGNORE INTO community_app_hot_meta(k,v) VALUES('master','1')"
    )
    c.commit()


def _now() -> float:
    return time.time()


def _meta(c, key: str, default: str = "") -> str:
    row = c.execute("SELECT v FROM community_app_hot_meta WHERE k=?", (key,)).fetchone()
    return str(row["v"]) if row else default


def _set_meta(c, key: str, value: str):
    c.execute(
        "INSERT INTO community_app_hot_meta(k,v) VALUES(?,?) "
        "ON CONFLICT(k) DO UPDATE SET v=excluded.v",
        (key, value),
    )


def _revision(c) -> int:
    try:
        return int(_meta(c, "revision", "0") or 0)
    except Exception:
        return 0


def _bump_revision(c) -> int:
    rev = _revision(c) + 1
    _set_meta(c, "revision", str(rev))
    _set_meta(c, "updated", str(_now()))
    return rev


def _admin_label(c, token: str) -> str:
    row = c.execute(
        "SELECT COALESCE(name,'') AS name, COALESCE(role,'') AS role"
        " FROM community_admins WHERE token=?",
        (token,),
    ).fetchone()
    if not row:
        return "admin"
    name = (row["name"] or "").strip()
    return name[:24] if name else (row["role"] or "admin")


def _parse_ts(v) -> float:
    if v is None or v == "":
        return 0.0
    if isinstance(v, (int, float)):
        x = float(v)
        # 毫秒时间戳兼容
        return x / 1000.0 if x > 1e12 else x
    s = str(v).strip()
    if not s:
        return 0.0
    try:
        return float(s)
    except Exception:
        pass
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.timestamp()
    except Exception:
        raise ValueError("时间格式不正确")


def _clean_text(v, max_len: int) -> str:
    s = "" if v is None else str(v)
    s = s.replace("\x00", "").strip()
    return s[:max_len]


def _parse_value(value_type: str, value):
    """把管理端传入的 value 规范成可 JSON 序列化的 Python 值。"""
    if value_type == "json":
        if isinstance(value, str):
            s = value.strip()
            if not s:
                raise ValueError("JSON 配置不能为空")
            try:
                value = json.loads(s)
            except Exception as e:
                raise ValueError("JSON 解析失败：%s" % e)
        if not isinstance(value, (dict, list)):
            raise ValueError("JSON 配置必须是对象或数组")
    elif value_type == "bool":
        if isinstance(value, bool):
            pass
        elif isinstance(value, str):
            value = value.strip().lower() in ("1", "true", "yes", "on")
        else:
            value = bool(value)
    elif value_type == "number":
        try:
            value = float(value)
        except Exception:
            raise ValueError("数字配置格式不正确")
        if value.is_integer():
            value = int(value)
    elif value_type == "string":
        value = "" if value is None else str(value)
    else:
        raise ValueError("未知配置类型")
    raw = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    if len(raw.encode("utf-8")) > MAX_VALUE_BYTES:
        raise ValueError("配置内容超过 32KB")
    return value, raw


def _normalize_value(key: str, value):
    """对客户端会执行的内置 key 做结构校验，避免后台填错把 App 弄坏。"""
    if key == "maintenance":
        if not isinstance(value, dict):
            raise ValueError("maintenance 必须是对象")
        out = {
            "enabled": bool(value.get("enabled", False)),
            "title": _clean_text(value.get("title"), 80),
            "message": _clean_text(value.get("message"), 600),
            "eta": _clean_text(value.get("eta"), 80),
            "updatedAt": int(_now()),
        }
        return out
    if key == "home_announcement":
        if not isinstance(value, dict):
            raise ValueError("home_announcement 必须是对象")
        enabled = bool(value.get("enabled", False))
        ann_id = _clean_text(value.get("id"), 64)
        if enabled and not ann_id:
            ann_id = "ann-" + uuid.uuid4().hex[:12]
        url = _clean_text(value.get("actionUrl"), 500)
        if url and not re.match(r"^https?://", url, re.I):
            raise ValueError("公告跳转链接必须以 http(s):// 开头")
        return {
            "enabled": enabled,
            "id": ann_id,
            "badge": _clean_text(value.get("badge"), 24),
            "title": _clean_text(value.get("title"), 80),
            "body": _clean_text(value.get("body"), 600),
            "actionText": _clean_text(value.get("actionText"), 32),
            "actionUrl": url,
            "dismissible": bool(value.get("dismissible", True)),
        }
    if key == "feature_flags":
        if not isinstance(value, dict):
            raise ValueError("feature_flags 必须是对象")
        if len(value) > 50:
            raise ValueError("功能开关过多")
        out = {}
        for k, v in value.items():
            k = str(k).strip()
            if not re.match(r"^[a-z][a-z0-9_]{0,40}$", k):
                raise ValueError("功能开关名不合法：%s" % k)
            if not isinstance(v, bool):
                raise ValueError("功能开关必须是 true/false：%s" % k)
            out[k] = v
        return out
    if key == "app_copy":
        if not isinstance(value, dict):
            raise ValueError("app_copy 必须是对象")
        if len(value) > 80:
            raise ValueError("文案项过多")
        out = {}
        for k, v in value.items():
            k = str(k).strip()
            if not re.match(r"^[a-z][a-z0-9_.-]{0,60}$", k):
                raise ValueError("文案键不合法：%s" % k)
            out[k] = _clean_text(v, 240)
        return out
    return value


def _value_of(row) -> object:
    try:
        return json.loads(row["value_json"])
    except Exception:
        return None


def _item(row) -> dict:
    d = row_dict(row)
    d["value"] = _value_of(row)
    for k in ("starts_at", "ends_at", "created", "updated", "published_at"):
        d[k] = float(d.get(k) or 0)
    for k in ("status", "priority", "min_build", "max_build", "rollout", "revision"):
        try:
            d[k] = int(d.get(k) or 0)
        except Exception:
            d[k] = 0
    d.pop("value_json", None)
    return d


def _snapshot(row) -> str:
    return json.dumps(_item(row), ensure_ascii=False, separators=(",", ":"))


def _audit(c, action: str, config_id: str, key: str, admin: str, detail: str = ""):
    c.execute(
        "INSERT INTO community_app_hot_audit(action,config_id,key,admin,detail,created)"
        " VALUES(?,?,?,?,?,?)",
        (action, config_id, key, admin, detail[:400], _now()),
    )


def _record_revision(c, row, action: str, admin: str):
    c.execute(
        "INSERT INTO community_app_hot_revisions(config_id,revision,action,snapshot_json,admin,created)"
        " VALUES(?,?,?,?,?,?)",
        (row["id"], int(row["revision"] or 0), action, _snapshot(row), admin, _now()),
    )


def _rollout_bucket(device: str, key: str) -> int:
    h = hashlib.sha256((device + "|" + key).encode("utf-8")).hexdigest()[:8]
    return int(h, 16) % 100


def _active_rows(c):
    return c.execute(
        "SELECT * FROM community_app_hot_configs WHERE status=1"
    ).fetchall()


def _channel_allowed(config_channel: str, client_channel: str) -> bool:
    """stable 配置对所有渠道可见；beta 追加测试配置；internal 全可见。"""
    c = (config_channel or "all").lower()
    if c == "all":
        return True
    if client_channel == "stable":
        return c == "stable"
    if client_channel == "beta":
        return c in ("stable", "beta")
    return True


def _manifest(c, platform: str, channel: str, build: int, device: str,
              preview: bool = False) -> dict:
    now = _now()
    master = _meta(c, "master", "1") == "1"
    revision = _revision(c)
    if not master:
        return {
            "revision": revision,
            "master": False,
            "configs": {},
            "count": 0,
            "platform": platform,
            "channel": channel,
            "generatedAt": int(now),
        }

    ranked = []
    chosen = {}
    for row in _active_rows(c):
        p = (row["platform"] or "all").lower()
        ch = (row["channel"] or "all").lower()
        if p not in ("all", platform) or not _channel_allowed(ch, channel):
            continue
        if row["starts_at"] and now < float(row["starts_at"]):
            continue
        if row["ends_at"] and now > float(row["ends_at"]):
            continue
        min_build = int(row["min_build"] or 0)
        max_build = int(row["max_build"] or 0)
        if build and min_build and build < min_build:
            continue
        if build and max_build and build > max_build:
            continue
        rollout = int(row["rollout"] if row["rollout"] is not None else 100)
        if not preview and rollout < 100:
            if _rollout_bucket(device or "anonymous", row["key"]) >= max(0, rollout):
                continue
        specificity = (
            1 if p == platform else 0,
            1 if ch == channel else 0,
        )
        ranked.append((specificity, int(row["priority"] or 0), float(row["updated"] or 0), row))

    # 从低优先级写入，高优先级覆盖：更具体的平台/渠道永远赢。
    ranked.sort(key=lambda x: (x[0][0], x[0][1], x[1], x[2]))
    for spec, prio, upd, row in ranked:
        key = row["key"]
        chosen[key] = _value_of(row)

    return {
        "revision": revision,
        "master": True,
        "configs": chosen,
        "count": len(chosen),
        "platform": platform,
        "channel": channel,
        "generatedAt": int(now),
    }


def _stats(c):
    rows = c.execute(
        "SELECT platform, channel, status, COUNT(*) AS n FROM community_app_hot_configs"
        " GROUP BY platform, channel, status"
    ).fetchall()
    out = {
        "total": 0,
        "active": 0,
        "draft": 0,
        "by_platform": {"all": 0, "android": 0, "ios": 0},
    }
    for r in rows:
        n = int(r["n"] or 0)
        out["total"] += n
        out["by_platform"][r["platform"]] = out["by_platform"].get(r["platform"], 0) + n
        if int(r["status"] or 0) == 1:
            out["active"] += n
        else:
            out["draft"] += n
    return out


def _query(handler) -> dict:
    q = parse_qs(urlparse(handler.path).query)
    return {k: (v[0] if v else "") for k, v in q.items()}


def _save(c, body: dict, admin: str) -> dict:
    key = _clean_text(body.get("key"), 64).lower()
    if not KEY_RE.match(key):
        raise ValueError("配置键需为小写字母开头，仅含小写字母/数字/._-")
    platform = _clean_text(body.get("platform") or "all", 12).lower()
    channel = _clean_text(body.get("channel") or "all", 12).lower()
    category = _clean_text(body.get("category") or "config", 16).lower()
    value_type = _clean_text(body.get("valueType") or "json", 12).lower()
    if platform not in PLATFORMS:
        raise ValueError("platform 只能是 all/android/ios")
    if channel not in CHANNELS:
        raise ValueError("channel 只能是 all/stable/beta/internal")
    if category not in CATEGORIES:
        raise ValueError("未知配置分类")
    if value_type not in VALUE_TYPES:
        raise ValueError("未知配置类型")

    value, value_json = _parse_value(value_type, body.get("value"))
    value = _normalize_value(key, value)
    value_json = json.dumps(value, ensure_ascii=False, separators=(",", ":"))

    try:
        priority = int(body.get("priority") or 0)
        min_build = max(0, int(body.get("minBuild") or 0))
        max_build = max(0, int(body.get("maxBuild") or 0))
        rollout = int(body.get("rollout") if body.get("rollout") is not None else 100)
    except Exception:
        raise ValueError("优先级 / build / 灰度必须是整数")
    if max_build and min_build and max_build < min_build:
        raise ValueError("maxBuild 不能小于 minBuild")
    if rollout < 0 or rollout > 100:
        raise ValueError("灰度比例需在 0-100 之间")
    starts_at = _parse_ts(body.get("startsAt"))
    ends_at = _parse_ts(body.get("endsAt"))
    if starts_at and ends_at and ends_at < starts_at:
        raise ValueError("结束时间不能早于开始时间")
    status = 1 if body.get("status") in (1, "1", True, "true", "active", "on") else 0
    revision = _bump_revision(c)
    now = _now()

    cid = _clean_text(body.get("id"), 64)
    if cid:
        current = c.execute(
            "SELECT * FROM community_app_hot_configs WHERE id=?", (cid,)
        ).fetchone()
        if not current:
            raise ValueError("配置不存在，可能已被删除")
        # 同 scope 同 key 不允许指向另一条记录
        dup = c.execute(
            "SELECT id FROM community_app_hot_configs WHERE platform=? AND channel=? AND key=? AND id<>?",
            (platform, channel, key, cid),
        ).fetchone()
        if dup:
            raise ValueError("同平台/渠道下已存在同名配置")
        published_at = float(current["published_at"] or 0)
        if status == 1 and not published_at:
            published_at = now
        created = float(current["created"] or now)
        created_by = current["created_by"] or admin
    else:
        dup = c.execute(
            "SELECT id FROM community_app_hot_configs WHERE platform=? AND channel=? AND key=?",
            (platform, channel, key),
        ).fetchone()
        if dup:
            raise ValueError("同平台/渠道下已存在同名配置")
        cid = "hot_" + uuid.uuid4().hex[:12]
        published_at = now if status == 1 else 0
        created = now
        created_by = admin

    c.execute(
        "INSERT INTO community_app_hot_configs("
        "id,key,category,platform,channel,value_type,value_json,description,status,priority,"
        "min_build,max_build,rollout,starts_at,ends_at,revision,created,updated,published_at,created_by"
        ") VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) "
        "ON CONFLICT(id) DO UPDATE SET "
        "key=excluded.key,category=excluded.category,platform=excluded.platform,"
        "channel=excluded.channel,value_type=excluded.value_type,value_json=excluded.value_json,"
        "description=excluded.description,status=excluded.status,priority=excluded.priority,"
        "min_build=excluded.min_build,max_build=excluded.max_build,rollout=excluded.rollout,"
        "starts_at=excluded.starts_at,ends_at=excluded.ends_at,revision=excluded.revision,"
        "updated=excluded.updated,published_at=excluded.published_at",
        (
            cid, key, category, platform, channel, value_type, value_json,
            _clean_text(body.get("description"), 240), status, priority,
            min_build, max_build, rollout, starts_at, ends_at, revision,
            created, now, published_at, created_by,
        ),
    )
    row = c.execute("SELECT * FROM community_app_hot_configs WHERE id=?", (cid,)).fetchone()
    _record_revision(c, row, "save", admin)
    _audit(c, "save", cid, key, admin,
           "platform=%s channel=%s status=%s rollout=%s" % (
               platform, channel, status, rollout))
    c.commit()
    return _item(row)


def _toggle(c, cid: str, body: dict, admin: str) -> dict:
    row = c.execute("SELECT * FROM community_app_hot_configs WHERE id=?", (cid,)).fetchone()
    if not row:
        raise ValueError("配置不存在")
    status = 1 if body.get("status") in (1, "1", True, "true", "active", "on") else 0
    rev = _bump_revision(c)
    now = _now()
    published_at = float(row["published_at"] or 0)
    if status == 1 and not published_at:
        published_at = now
    c.execute(
        "UPDATE community_app_hot_configs SET status=?, revision=?, updated=?, published_at=?"
        " WHERE id=?",
        (status, rev, now, published_at, cid),
    )
    updated = c.execute("SELECT * FROM community_app_hot_configs WHERE id=?", (cid,)).fetchone()
    _record_revision(c, updated, "publish" if status else "disable", admin)
    _audit(c, "publish" if status else "disable", cid, row["key"], admin, "")
    c.commit()
    return _item(updated)


def _delete(c, cid: str, admin: str) -> dict:
    row = c.execute("SELECT * FROM community_app_hot_configs WHERE id=?", (cid,)).fetchone()
    if not row:
        raise ValueError("配置不存在")
    _bump_revision(c)
    c.execute("DELETE FROM community_app_hot_configs WHERE id=?", (cid,))
    _audit(c, "delete", cid, row["key"], admin, "删除配置")
    c.commit()
    return _item(row)


def _rollback(c, cid: str, body: dict, admin: str) -> dict:
    try:
        target = int(body.get("revision") or 0)
    except Exception:
        raise ValueError("revision 必须是整数")
    rev_row = c.execute(
        "SELECT * FROM community_app_hot_revisions WHERE config_id=? AND revision=? "
        "ORDER BY id DESC LIMIT 1",
        (cid, target),
    ).fetchone()
    if not rev_row:
        raise ValueError("找不到该历史版本")
    try:
        snap = json.loads(rev_row["snapshot_json"])
    except Exception:
        raise ValueError("历史版本损坏")
    value_json = json.dumps(snap.get("value"), ensure_ascii=False, separators=(",", ":"))
    rev = _bump_revision(c)
    now = _now()
    c.execute(
        "UPDATE community_app_hot_configs SET category=?,platform=?,channel=?,value_type=?,"
        "value_json=?,description=?,status=?,priority=?,min_build=?,max_build=?,rollout=?,"
        "starts_at=?,ends_at=?,revision=?,updated=?,published_at=? WHERE id=?",
        (
            snap.get("category") or "config", snap.get("platform") or "all",
            snap.get("channel") or "all", snap.get("value_type") or "json", value_json,
            snap.get("description") or "", int(snap.get("status") or 0),
            int(snap.get("priority") or 0), int(snap.get("min_build") or 0),
            int(snap.get("max_build") or 0), int(snap.get("rollout") or 100),
            float(snap.get("starts_at") or 0), float(snap.get("ends_at") or 0),
            rev, now, float(snap.get("published_at") or 0), cid,
        ),
    )
    updated = c.execute("SELECT * FROM community_app_hot_configs WHERE id=?", (cid,)).fetchone()
    _record_revision(c, updated, "rollback", admin)
    _audit(c, "rollback", cid, updated["key"], admin, "回滚到 revision %s" % target)
    c.commit()
    return _item(updated)


def _master(c, body: dict, admin: str) -> dict:
    enabled = body.get("enabled")
    if isinstance(enabled, str):
        enabled = enabled.strip().lower() in ("1", "true", "yes", "on")
    enabled = bool(enabled)
    _set_meta(c, "master", "1" if enabled else "0")
    rev = _bump_revision(c)
    _audit(c, "master_on" if enabled else "master_off", "", "", admin,
           "热更新总开关：%s" % ("开启" if enabled else "关闭"))
    c.commit()
    return {"master": enabled, "revision": rev}


def _admin_list(c) -> dict:
    rows = c.execute(
        "SELECT * FROM community_app_hot_configs "
        "ORDER BY status DESC, updated DESC, key ASC"
    ).fetchall()
    audits = c.execute(
        "SELECT * FROM community_app_hot_audit ORDER BY id DESC LIMIT 60"
    ).fetchall()
    return {
        "revision": _revision(c),
        "master": _meta(c, "master", "1") == "1",
        "items": [_item(r) for r in rows],
        "audit": [row_dict(r) for r in audits],
        "stats": _stats(c),
        "platforms": list(PLATFORMS),
        "channels": list(CHANNELS),
        "categories": list(CATEGORIES),
        "valueTypes": list(VALUE_TYPES),
        "serverTime": int(_now()),
    }


def _revisions(c, cid: str) -> dict:
    rows = c.execute(
        "SELECT id,config_id,revision,action,admin,created,snapshot_json "
        "FROM community_app_hot_revisions WHERE config_id=? ORDER BY revision DESC, id DESC LIMIT 40",
        (cid,),
    ).fetchall()
    out = []
    for r in rows:
        d = row_dict(r)
        try:
            d["snapshot"] = json.loads(d.pop("snapshot_json", "{}"))
        except Exception:
            d["snapshot"] = {}
        out.append(d)
    return {"items": out}


def _require_admin(c, handler):
    from handlers.admin_api import _authed
    return _authed(c, handler)


def dispatch(self, c, u, api, method) -> bool:
    """路由：公开清单 + 管理端配置中心。返回 True 表示已处理。"""
    if api == "/app/hot-update" and method == "GET":
        q = _query(self)
        platform = (q.get("platform") or "android").lower()
        if platform not in ("android", "ios"):
            self._err(400, "platform 只能是 android/ios")
            return True
        channel = (q.get("channel") or "stable").lower()
        if channel not in CHANNELS or channel == "all":
            channel = "stable"
        try:
            build = int(q.get("build") or 0)
        except Exception:
            build = 0
        device = (q.get("device") or "").strip()[:96]
        if not device:
            device = "%s|%s" % (
                self.headers.get("CF-Connecting-IP", "") or self.client_address[0],
                self.headers.get("User-Agent", "")[:120],
            )
        m = _manifest(c, platform, channel, build, device, preview=False)
        self._ok(m)
        return True

    if not (api == "/admin/hot-update" or api.startswith("/admin/hot-update/")):
        return False
    auth = _require_admin(c, self)
    if not auth:
        return True
    token = auth[0]
    admin = _admin_label(c, token)

    try:
        if api == "/admin/hot-update" and method == "GET":
            self._ok(_admin_list(c))
            return True

        if api == "/admin/hot-update/configs" and method == "POST":
            body = self._json_body()
            if body is None:
                self._err(413, "请求体过大")
                return True
            row = _save(c, body, admin)
            self._ok({"item": row, "revision": _revision(c)})
            return True

        m = re.match(r"^/admin/hot-update/configs/([^/]+)$", api)
        if m and method == "DELETE":
            row = _delete(c, m.group(1), admin)
            self._ok({"item": row, "revision": _revision(c)})
            return True

        m = re.match(r"^/admin/hot-update/configs/([^/]+)/toggle$", api)
        if m and method == "POST":
            body = self._json_body() or {}
            row = _toggle(c, m.group(1), body, admin)
            self._ok({"item": row, "revision": _revision(c)})
            return True

        m = re.match(r"^/admin/hot-update/configs/([^/]+)/revisions$", api)
        if m and method == "GET":
            self._ok(_revisions(c, m.group(1)))
            return True

        m = re.match(r"^/admin/hot-update/configs/([^/]+)/rollback$", api)
        if m and method == "POST":
            body = self._json_body() or {}
            row = _rollback(c, m.group(1), body, admin)
            self._ok({"item": row, "revision": _revision(c)})
            return True

        if api == "/admin/hot-update/master" and method == "POST":
            body = self._json_body() or {}
            self._ok(_master(c, body, admin))
            return True

        if api == "/admin/hot-update/preview" and method == "GET":
            q = _query(self)
            platform = (q.get("platform") or "ios").lower()
            if platform not in ("android", "ios"):
                platform = "ios"
            channel = (q.get("channel") or "stable").lower()
            if channel not in CHANNELS or channel == "all":
                channel = "stable"
            try:
                build = int(q.get("build") or 0)
            except Exception:
                build = 0
            m = _manifest(c, platform, channel, build,
                          q.get("device") or "admin-preview", preview=True)
            self._ok(m)
            return True

        self._err(404, "接口不存在")
        return True
    except ValueError as e:
        self._err(400, str(e))
        return True
    except Exception as e:
        self._err(500, "热更新服务异常：%s" % e)
        return True
