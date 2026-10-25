# -*- coding: utf-8 -*-
"""流萤社区 · 数据库 Schema（31 张社区表，全部幂等 CREATE TABLE IF NOT EXISTS）。

零侵入红线：
- 绝不创建/修改音乐任何表（users/tokens/follows/notifications 为共享只读/授权写入）。
- 本模块只建 community_* 前缀的表；共享表结构见 music server/database.py。
"""
import os
import time
import uuid

DB_PATH = os.environ.get("COMMUNITY_DB", "/www/wwwroot/music/tracks.db")
FILES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "files")

_TABLES = [
    # ============ 内容域 ============
    """
    CREATE TABLE IF NOT EXISTS community_posts(
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        type TEXT DEFAULT 'text',          -- 'text' / 'video' / 'poll'
        content TEXT DEFAULT '',           -- 富文本原文（#话题 @昵称 [表情code]）
        images TEXT DEFAULT '[]',          -- JSON ≤3 张 community_img_*
        video TEXT DEFAULT '',             -- 视频文件名 community_video_*
        cover TEXT DEFAULT '',             -- 封面文件名（自动/指定帧/上传）
        duration REAL DEFAULT 0,
        board_id TEXT DEFAULT '',
        tag TEXT DEFAULT '',
        topic TEXT DEFAULT '[]',           -- 话题 JSON
        mentions TEXT DEFAULT '[]',        -- @ 用户 JSON [{id,name}]
        poll TEXT DEFAULT '',              -- 投票定义 JSON {question,options,votes,endAt,multi}
        like_count INTEGER DEFAULT 0,
        comment_count INTEGER DEFAULT 0,
        share_count INTEGER DEFAULT 0,
        sticky INTEGER DEFAULT 0,
        featured INTEGER DEFAULT 0,
        featured_at REAL DEFAULT 0,
        taken_down INTEGER DEFAULT 0,
        taken_down_reason TEXT DEFAULT '',
        status INTEGER DEFAULT 1,          -- 1 正常 / 0 软删
        audit_status INTEGER DEFAULT 0,    -- 0 待审 / 1 通过 / 2 拒绝
        audit_reason TEXT DEFAULT '',
        audited_at REAL DEFAULT 0,
        edited_at REAL DEFAULT 0,
        created REAL
    )""",
    "CREATE INDEX IF NOT EXISTS idx_cpost_feed ON community_posts(status, audit_status, created DESC)",
    "CREATE INDEX IF NOT EXISTS idx_cpost_board ON community_posts(board_id, created DESC)",
    "CREATE INDEX IF NOT EXISTS idx_cpost_user ON community_posts(user_id, created DESC)",
    "CREATE INDEX IF NOT EXISTS idx_cpost_type ON community_posts(type, created DESC)",
    "CREATE INDEX IF NOT EXISTS idx_cpost_audit ON community_posts(audit_status, created DESC)",
    "CREATE INDEX IF NOT EXISTS idx_cpost_topic ON community_posts(topic)",
    """
    CREATE TABLE IF NOT EXISTS community_post_likes(
        user_id TEXT NOT NULL, post_id TEXT NOT NULL, created REAL,
        PRIMARY KEY(user_id, post_id))""",
    "CREATE INDEX IF NOT EXISTS idx_cpl_post ON community_post_likes(post_id)",
    """
    CREATE TABLE IF NOT EXISTS community_post_comments(
        id TEXT PRIMARY KEY,
        post_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        content TEXT DEFAULT '',           -- 文字 + 混排表情 code
        images TEXT DEFAULT '[]',          -- 1 张上传图片（与 sticker 二选一）
        sticker TEXT DEFAULT '',           -- 1 个图片表情包（静态/动图）
        like_count INTEGER DEFAULT 0,
        pinned INTEGER DEFAULT 0,
        pinned_at REAL DEFAULT 0,
        status INTEGER DEFAULT 1,
        created REAL)""",
    "CREATE INDEX IF NOT EXISTS idx_cpc_post ON community_post_comments(post_id, created DESC)",
    "CREATE INDEX IF NOT EXISTS idx_cpc_user ON community_post_comments(user_id, created DESC)",
    """
    CREATE TABLE IF NOT EXISTS community_post_comment_likes(
        user_id TEXT NOT NULL, comment_id TEXT NOT NULL, created REAL,
        PRIMARY KEY(user_id, comment_id))""",
    """
    CREATE TABLE IF NOT EXISTS community_shares(
        user_id TEXT NOT NULL, post_id TEXT NOT NULL, created REAL,
        PRIMARY KEY(user_id, post_id))""",
    # ============ 组织域 ============
    """
    CREATE TABLE IF NOT EXISTS community_boards(
        id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE,
        parent_id TEXT DEFAULT '', icon TEXT DEFAULT '📌',
        color TEXT DEFAULT '#4FC3F7', sort INTEGER DEFAULT 0,
        active INTEGER DEFAULT 1, post_count INTEGER DEFAULT 0, created REAL)""",
    "CREATE INDEX IF NOT EXISTS idx_cboard_parent ON community_boards(parent_id, sort)",
    """
    CREATE TABLE IF NOT EXISTS community_topics(
        id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE,
        post_count INTEGER DEFAULT 0, created REAL)""",
    "CREATE INDEX IF NOT EXISTS idx_ctopic_hot ON community_topics(post_count DESC)",
    # ============ 用户域 ============
    """
    CREATE TABLE IF NOT EXISTS community_exp(
        user_id TEXT PRIMARY KEY, exp INTEGER DEFAULT 0,
        level INTEGER DEFAULT 0, updated REAL)""",
    """
    CREATE TABLE IF NOT EXISTS community_frames(
        id TEXT PRIMARY KEY, name TEXT NOT NULL,
        image TEXT DEFAULT '', image_dynamic TEXT DEFAULT '',
        sort INTEGER DEFAULT 0, active INTEGER DEFAULT 1, created REAL)""",
    """
    CREATE TABLE IF NOT EXISTS community_user_frames(
        user_id TEXT PRIMARY KEY, frame_id TEXT DEFAULT '', updated REAL)""",
    """
    CREATE TABLE IF NOT EXISTS community_emojis(
        id TEXT PRIMARY KEY, code TEXT NOT NULL UNIQUE,
        image TEXT NOT NULL, category TEXT DEFAULT '默认',
        sort INTEGER DEFAULT 0, active INTEGER DEFAULT 1, created REAL)""",
    "CREATE INDEX IF NOT EXISTS idx_cemoji_cat ON community_emojis(category, sort)",
    """
    CREATE TABLE IF NOT EXISTS community_user_emojis(
        user_id TEXT NOT NULL, emoji_id TEXT NOT NULL, created REAL,
        PRIMARY KEY(user_id, emoji_id))""",
    # ============ 治理域 ============
    """
    CREATE TABLE IF NOT EXISTS community_official_messages(
        id TEXT PRIMARY KEY, content TEXT NOT NULL,
        sender_name TEXT DEFAULT '流萤社区官方',
        receiver_user_id TEXT DEFAULT '', created REAL)""",
    "CREATE INDEX IF NOT EXISTS idx_comsg ON community_official_messages(receiver_user_id, created DESC)",
    """
    CREATE TABLE IF NOT EXISTS community_official_read(
        user_id TEXT PRIMARY KEY, last_read REAL DEFAULT 0)""",
    """
    CREATE TABLE IF NOT EXISTS community_admins(
        token TEXT PRIMARY KEY,
        user_id TEXT DEFAULT '',
        level INTEGER DEFAULT 2,           -- 1 一级 / 2 二级
        name TEXT DEFAULT '社区管理员', created REAL)""",
    """
    CREATE TABLE IF NOT EXISTS community_admin_logs(
        id TEXT PRIMARY KEY, admin_token TEXT NOT NULL,
        action TEXT NOT NULL, target_type TEXT DEFAULT '',
        target_id TEXT DEFAULT '', detail TEXT DEFAULT '', created REAL)""",
    "CREATE INDEX IF NOT EXISTS idx_cadminlog ON community_admin_logs(created DESC)",
    """
    CREATE TABLE IF NOT EXISTS community_members(
        user_id TEXT PRIMARY KEY, level TEXT DEFAULT '',
        expire REAL DEFAULT 0, created REAL, updated REAL)""",
    # ============ v4 扩展域 ============
    """
    CREATE TABLE IF NOT EXISTS community_favorites(
        user_id TEXT NOT NULL, post_id TEXT NOT NULL,
        kind TEXT DEFAULT 'fav', created REAL,
        PRIMARY KEY(user_id, post_id, kind))""",
    "CREATE INDEX IF NOT EXISTS idx_cfav_user ON community_favorites(user_id, kind, created DESC)",
    """
    CREATE TABLE IF NOT EXISTS community_reports(
        id TEXT PRIMARY KEY, target_type TEXT DEFAULT 'post',
        target_id TEXT NOT NULL, user_id TEXT NOT NULL,
        reason TEXT DEFAULT '', status INTEGER DEFAULT 0,
        result TEXT DEFAULT '', created REAL)""",
    "CREATE INDEX IF NOT EXISTS idx_creport ON community_reports(status, created DESC)",
    """
    CREATE TABLE IF NOT EXISTS community_blocks(
        user_id TEXT NOT NULL, blocked_id TEXT NOT NULL, created REAL,
        PRIMARY KEY(user_id, blocked_id))""",
    """
    CREATE TABLE IF NOT EXISTS community_sensitive_words(
        id TEXT PRIMARY KEY, word TEXT NOT NULL UNIQUE,
        level INTEGER DEFAULT 0, active INTEGER DEFAULT 1, created REAL)""",
    """
    CREATE TABLE IF NOT EXISTS community_user_prefs(
        user_id TEXT PRIMARY KEY,
        notify_mask TEXT DEFAULT '{}',
        quiet_start TEXT DEFAULT '', quiet_end TEXT DEFAULT '',
        comment_perm INTEGER DEFAULT 0,    -- 0 所有人 / 1 仅关注 / 2 关闭
        profile_visible INTEGER DEFAULT 0, -- 0 公开 / 1 仅关注
        theme TEXT DEFAULT 'dark', updated REAL)""",
    """
    CREATE TABLE IF NOT EXISTS community_signins(
        user_id TEXT NOT NULL, day TEXT NOT NULL, created REAL,
        PRIMARY KEY(user_id, day))""",
    """
    CREATE TABLE IF NOT EXISTS community_tasks(
        id TEXT PRIMARY KEY, name TEXT NOT NULL,
        type TEXT DEFAULT 'newbie', target INTEGER DEFAULT 1,
        reward_exp INTEGER DEFAULT 10, active INTEGER DEFAULT 1, created REAL)""",
    """
    CREATE TABLE IF NOT EXISTS community_user_tasks(
        user_id TEXT NOT NULL, task_id TEXT NOT NULL,
        progress INTEGER DEFAULT 0, done INTEGER DEFAULT 0,
        claimed INTEGER DEFAULT 0, PRIMARY KEY(user_id, task_id))""",
    """
    CREATE TABLE IF NOT EXISTS community_poll_votes(
        user_id TEXT NOT NULL, post_id TEXT NOT NULL,
        option INTEGER DEFAULT 0, created REAL,
        PRIMARY KEY(user_id, post_id))""",
    """
    CREATE TABLE IF NOT EXISTS community_feedback(
        id TEXT PRIMARY KEY, user_id TEXT NOT NULL,
        type TEXT DEFAULT 'other',    -- bug | suggestion | other
        content TEXT NOT NULL,
        contact TEXT DEFAULT '',      -- 联系方式（邮箱等，选填）
        status INTEGER DEFAULT 0,     -- 0 待处理 / 1 已处理 / 2 已忽略
        reply TEXT DEFAULT '',        -- 处理备注
        created REAL, updated REAL)""",
    """
    CREATE TABLE IF NOT EXISTS community_banners(
        id TEXT PRIMARY KEY, image TEXT NOT NULL,
        link_type TEXT DEFAULT 'url', link_id TEXT DEFAULT '',
        sort INTEGER DEFAULT 0, active INTEGER DEFAULT 1,
        start_at REAL DEFAULT 0, end_at REAL DEFAULT 0, created REAL)""",
    """
    CREATE TABLE IF NOT EXISTS community_activities(
        id TEXT PRIMARY KEY, topic_id TEXT DEFAULT '', title TEXT NOT NULL,
        desc TEXT DEFAULT '', reward_exp INTEGER DEFAULT 0,
        start_at REAL DEFAULT 0, end_at REAL DEFAULT 0,
        status INTEGER DEFAULT 0, created REAL)""",
    """
    CREATE TABLE IF NOT EXISTS community_conversations(
        id TEXT PRIMARY KEY, user_a TEXT NOT NULL, user_b TEXT NOT NULL,
        last_msg TEXT DEFAULT '', last_time REAL DEFAULT 0,
        unread_a INTEGER DEFAULT 0, unread_b INTEGER DEFAULT 0, created REAL)""",
    "CREATE INDEX IF NOT EXISTS idx_cconv_a ON community_conversations(user_a, last_time DESC)",
    "CREATE INDEX IF NOT EXISTS idx_cconv_b ON community_conversations(user_b, last_time DESC)",
    """
    CREATE TABLE IF NOT EXISTS community_messages(
        id TEXT PRIMARY KEY, conv_id TEXT NOT NULL, sender TEXT NOT NULL,
        content TEXT DEFAULT '', type TEXT DEFAULT 'text',
        created REAL, read_at REAL DEFAULT 0)""",
    "CREATE INDEX IF NOT EXISTS idx_cmsg ON community_messages(conv_id, created)",
    """
    CREATE TABLE IF NOT EXISTS community_search_logs(
        id TEXT PRIMARY KEY, user_id TEXT DEFAULT '', q TEXT NOT NULL, created REAL)""",
    "CREATE INDEX IF NOT EXISTS idx_csearch ON community_search_logs(q, created)",
    """
    CREATE TABLE IF NOT EXISTS community_drafts(
        id TEXT PRIMARY KEY, user_id TEXT NOT NULL,
        type TEXT DEFAULT 'text', content TEXT DEFAULT '',
        images TEXT DEFAULT '[]', video TEXT DEFAULT '',
        board_id TEXT DEFAULT '', topic TEXT DEFAULT '[]',
        mentions TEXT DEFAULT '[]', poll TEXT DEFAULT '',
        created REAL, updated REAL)""",
    "CREATE INDEX IF NOT EXISTS idx_cdraft_user ON community_drafts(user_id, updated DESC)",
    """
    CREATE TABLE IF NOT EXISTS community_videos(
        id TEXT PRIMARY KEY, user_id TEXT NOT NULL,
        duration REAL DEFAULT 0, status TEXT DEFAULT 'processing',
        cover TEXT DEFAULT '', error TEXT DEFAULT '',
        created REAL, updated REAL)""",
    "CREATE INDEX IF NOT EXISTS idx_cvideo_user ON community_videos(user_id, created DESC)",
]

_DEFAULT_TASKS = [
    # 新手任务：完善资料 / 首帖 / 首视频 / 首评 / 首赞 / 首分享 / 关注 1 人 / 签到 3 天
    ("t_profile", "完善个人资料", "newbie", 1, 20),
    ("t_first_post", "发布第一篇帖子", "newbie", 1, 20),
    ("t_first_video", "发布第一条短视频", "newbie", 1, 30),
    ("t_first_comment", "发表第一条评论", "newbie", 1, 10),
    ("t_first_like", "第一次点赞", "newbie", 1, 5),
    ("t_first_share", "第一次分享", "newbie", 1, 10),
    ("t_follow1", "关注 1 位用户", "newbie", 1, 10),
    ("t_signin3", "累计签到 3 天", "daily", 3, 15),
]


def init_schema():
    """幂等建表 + 初始数据（默认版块/默认任务）。只操作 community_* 表。"""
    import sqlite3
    c = sqlite3.connect(DB_PATH, timeout=10)
    try:
        c.execute("PRAGMA journal_mode=WAL")
        c.execute("PRAGMA busy_timeout=5000")
        c.execute("PRAGMA synchronous=NORMAL")
        for ddl in _TABLES:
            c.execute(ddl)
        _seed_boards(c)
        _seed_tasks(c)
        c.commit()
    finally:
        c.close()


def _seed_boards(c):
    """首发 6 版块（幂等：仅当表空）。"""
    if c.execute("SELECT COUNT(*) FROM community_boards").fetchone()[0]:
        return
    now = time.time()
    for i, (name, icon, color) in enumerate([
            ("生活分享", "🍀", "#4FC3F7"),
            ("美食探店", "🍜", "#FF8A65"),
            ("户外运动", "🏔️", "#81C784"),
            ("数码科技", "💻", "#9575CD"),
            ("同城活动", "📍", "#FFD54F"),
            ("萌宠日常", "🐱", "#F48FB1")]):
        c.execute("INSERT INTO community_boards(id,name,parent_id,icon,color,sort,active,created)"
                  " VALUES(?,?,?,?,?,?,1,?)",
                  (uuid.uuid4().hex, name, "", icon, color, i, now))


def _seed_tasks(c):
    if c.execute("SELECT COUNT(*) FROM community_tasks").fetchone()[0]:
        return
    now = time.time()
    for tid, name, typ, target, reward in _DEFAULT_TASKS:
        c.execute("INSERT INTO community_tasks(id,name,type,target,reward_exp,active,created)"
                  " VALUES(?,?,?,?,?,1,?)",
                  (tid, name, typ, target, reward, now))
