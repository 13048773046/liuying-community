# -*- coding: utf-8 -*-
"""流小萤 · 社区 AI 账号数据表。

只新增 ai_bot_* 表，不改社区/音乐既有表结构。
"""
import json
import time

TABLES = [
    """
    CREATE TABLE IF NOT EXISTS ai_bot_config(
        key TEXT PRIMARY KEY,
        value TEXT DEFAULT '',
        updated REAL DEFAULT 0)""",
    """
    CREATE TABLE IF NOT EXISTS ai_bot_actions(
        id TEXT PRIMARY KEY,
        kind TEXT DEFAULT '',
        target_id TEXT DEFAULT '',
        dedupe_key TEXT DEFAULT NULL,
        detail TEXT DEFAULT '',
        status TEXT DEFAULT 'done',
        result TEXT DEFAULT '',
        created REAL DEFAULT 0,
        updated REAL DEFAULT 0)""",
    "CREATE INDEX IF NOT EXISTS idx_aibot_action_created ON ai_bot_actions(created DESC)",
    "CREATE INDEX IF NOT EXISTS idx_aibot_action_kind ON ai_bot_actions(kind, created DESC)",
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_aibot_action_dedupe ON ai_bot_actions(dedupe_key) WHERE dedupe_key IS NOT NULL",
    """
    CREATE TABLE IF NOT EXISTS ai_bot_conversations(
        peer_id TEXT PRIMARY KEY,
        state_json TEXT DEFAULT '{}',
        last_msg_id TEXT DEFAULT '',
        last_msg_at REAL DEFAULT 0,
        created REAL DEFAULT 0,
        updated REAL DEFAULT 0)""",
    "CREATE INDEX IF NOT EXISTS idx_aibot_conv_updated ON ai_bot_conversations(updated DESC)",
    """
    CREATE TABLE IF NOT EXISTS ai_bot_dm_seen(
        message_id TEXT PRIMARY KEY,
        peer_id TEXT DEFAULT '',
        created REAL DEFAULT 0)""",
]

DEFAULT_POLICY = {
    "enabled": True,
    "auto_followback": True,
    "auto_dm": True,
    "auto_publish": True,
    "auto_schedule": True,           # 自主排期：由模型决定下一次时间
    "auto_engage": True,
    "post_interval": 10800,          # 3 小时
    "video_interval": 28800,         # 8 小时
    "app_interval": 86400,           # 24 小时
    "engage_interval": 1200,         # 20 分钟
    "max_posts_per_day": 4,
    "max_videos_per_day": 2,
    "max_apps_per_day": 1,
    "max_likes_per_day": 30,
    "max_comments_per_day": 8,
    "max_favs_per_day": 15,
    "max_app_comments_per_day": 3,
    "max_dm_actions_per_user_day": 80,
    "max_dm_replies_per_minute": 60,
    "min_media_width": 720,
    "dry_run": False,
    "topics": [
        "雨后的街道", "城市夜色", "山间清晨", "海边的风", "咖啡与书",
        "午睡的猫", "森林小路", "旧车站", "夏夜的灯", "窗边的光",
        "云层之上", "街头烟火", "湖面倒影", "黄昏公路", "安静的角落",
    ],
}


USER_MIGRATION_COLUMNS = (
    ("is_ai", "INTEGER DEFAULT 0"),
    ("signature", "TEXT DEFAULT ''"),
    ("verified", "TEXT DEFAULT ''"),
    ("verified_label", "TEXT DEFAULT ''"),
    ("title", "TEXT DEFAULT ''"),
    ("email", "TEXT DEFAULT ''"),
)


def _ensure_user_columns(c):
    """音乐侧 users 表可能来自旧库；先补齐 AI 账号依赖的列。

    不能假设线上/测试夹具的 users 表结构与最新音乐端完全一致。缺列时
    SELECT 会直接抛 OperationalError，整个社区服务都起不来。
    """
    cols = {str(r[1]) for r in c.execute("PRAGMA table_info(users)").fetchall()}
    if not cols or "id" not in cols:
        return None
    for name, ddl in USER_MIGRATION_COLUMNS:
        if name not in cols:
            c.execute("ALTER TABLE users ADD COLUMN %s %s" % (name, ddl))
    return cols


def _ensure_bot(c):
    """保证官方账号存在且标记为 AI；只补齐空字段，不改名字/头像。"""
    cols = _ensure_user_columns(c)
    # 独立后端架构测试只有社区表、没有音乐侧 users 表；跳过官方账号，
    # 不能让一个可选 AI 账号把整个服务启动拖死。
    if not cols:
        return
    now = time.time()
    row = c.execute("SELECT id,name,is_ai,signature,verified,verified_label,title"
                    " FROM users WHERE id='ai_liuying_comment'").fetchone()
    if not row:
        c.execute(
            "INSERT INTO users(id,account,name,avatar,created,gender,age,background_image,"
            "signature,ip_address,banned,is_ai,city,title,verified,verified_label,member,member_expire,svip_expire,email)"
            " VALUES('ai_liuying_comment','000000','流小萤','',?, '',0,'','', '',0,1,'','', '','', '',0,0,'')",
            (now,))
        return
    sets, args = [], []
    if not int(row[2] or 0):
        sets.append("is_ai=?")
        args.append(1)
    if not str(row[3] or "").strip():
        sets.append("signature=?")
        args.append("住在流萤里的 AI，会发帖，也会陪你聊天。")
    if not str(row[4] or "").strip():
        sets.append("verified=?")
        args.append("1")
    if not str(row[5] or "").strip():
        sets.append("verified_label=?")
        args.append("AI")
    if not str(row[6] or "").strip():
        sets.append("title=?")
        args.append("社区 AI")
    if sets:
        c.execute("UPDATE users SET " + ",".join(sets) + " WHERE id='ai_liuying_comment'",
                  args)


def init_ai_bot_schema(c):
    for ddl in TABLES:
        c.execute(ddl)
    _ensure_bot(c)
    row = c.execute("SELECT value FROM ai_bot_config WHERE key='policy'").fetchone()
    if not row:
        c.execute("INSERT INTO ai_bot_config(key,value,updated) VALUES('policy',?,?)",
                  (json.dumps(DEFAULT_POLICY, ensure_ascii=False), time.time()))
