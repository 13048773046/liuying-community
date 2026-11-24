# -*- coding: utf-8 -*-
"""流萤社区 · 数据库 Schema（31 张社区表，全部幂等 CREATE TABLE IF NOT EXISTS）。

零侵入红线：
- 绝不创建/修改音乐任何表（users/tokens/follows/notifications 为共享只读/授权写入）。
- 本模块只建 community_* 前缀的表；共享表结构见 music server/database.py。
"""
import os
import time
import uuid

from core.settings import settings

DB_PATH = settings.db_path
FILES_DIR = settings.files_dir

_TABLES = [
    # ============ 内容域 ============
    """
    CREATE TABLE IF NOT EXISTS community_posts(
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        type TEXT DEFAULT 'text',          -- 'text' / 'video' / 'poll'
        content TEXT DEFAULT '',           -- 富文本原文（#话题 @昵称 [表情code]）
        images TEXT DEFAULT '[]',          -- JSON ≤3 张 community_img_*
        music TEXT DEFAULT '',             -- JSON 配乐 {url,name,cover,trackId}
        audio_volume INTEGER DEFAULT 100,  -- 原声音量 0-100
        music_volume INTEGER DEFAULT 50,   -- 配乐音量 0-100
        video TEXT DEFAULT '',             -- 视频文件名 community_video_*
        cover TEXT DEFAULT '',             -- 封面文件名（自动/指定帧/上传）
        duration REAL DEFAULT 0,
        board_id TEXT DEFAULT '',
        tag TEXT DEFAULT '',
        topic TEXT DEFAULT '[]',           -- 话题 JSON
        mentions TEXT DEFAULT '[]',        -- @ 用户 JSON [{id,name}]
        poll TEXT DEFAULT '',              -- 投票定义 JSON {question,options,votes,endAt,multi}
        attachments TEXT DEFAULT '[]',     -- JSON ≤2 个帖子附件 {name,label,size,ext,mime}
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
    # ============ 个性化推荐域 ============
    """
    CREATE TABLE IF NOT EXISTS community_behavior_events(
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        post_id TEXT NOT NULL,
        event TEXT NOT NULL,               -- view/like/fav/comment/share/vote/open/not_interested
        value REAL DEFAULT 0,
        meta TEXT DEFAULT '',              -- 事件快照 JSON（board/topic/author）
        created REAL)""",
    "CREATE INDEX IF NOT EXISTS idx_cbe_user ON community_behavior_events(user_id, created DESC)",
    "CREATE INDEX IF NOT EXISTS idx_cbe_post ON community_behavior_events(post_id, event, created DESC)",
    "CREATE INDEX IF NOT EXISTS idx_cbe_event ON community_behavior_events(event, created DESC)",
    """
    CREATE TABLE IF NOT EXISTS community_recommend_push(
        uid TEXT NOT NULL, post_id TEXT NOT NULL, pushed_at REAL,
        PRIMARY KEY(uid, post_id))""",
    "CREATE INDEX IF NOT EXISTS idx_crp_time ON community_recommend_push(uid, pushed_at)",
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
        post_count INTEGER DEFAULT 0, created_by TEXT DEFAULT '', created REAL)""",
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
        sort INTEGER DEFAULT 0, active INTEGER DEFAULT 1, created REAL,
        owner_id TEXT DEFAULT '')""",
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
        receiver_user_id TEXT DEFAULT '', created REAL,
        content_type TEXT DEFAULT 'text',   -- text / rich
        plain_text TEXT DEFAULT '')         -- 富文本的纯文本 fallback / 列表摘要""",
    "CREATE INDEX IF NOT EXISTS idx_comsg ON community_official_messages(receiver_user_id, created DESC)",
    """
    CREATE TABLE IF NOT EXISTS community_official_read(
        user_id TEXT PRIMARY KEY, last_read REAL DEFAULT 0)""",
    """
    CREATE TABLE IF NOT EXISTS community_admins(
        token TEXT PRIMARY KEY,
        user_id TEXT DEFAULT '',
        level INTEGER DEFAULT 2,           -- 1 一级 / 2 二级
        role TEXT DEFAULT '',             -- super/admin/auditor
        perms TEXT DEFAULT '',            -- 逗号分隔模块权限
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
        title TEXT DEFAULT '',
        sort INTEGER DEFAULT 0, active INTEGER DEFAULT 1,
        start_at REAL DEFAULT 0, end_at REAL DEFAULT 0, created REAL)""",
    """
    CREATE TABLE IF NOT EXISTS community_banner_fallback(
        id TEXT PRIMARY KEY, enabled INTEGER DEFAULT 1,
        title TEXT DEFAULT '社区活动进行中',
        subtitle TEXT DEFAULT '签到、发帖、互动都能涨经验，冲等级解锁装扮',
        link_type TEXT DEFAULT 'task', link_id TEXT DEFAULT '',
        updated REAL)""",
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
    # ============ 会员域（VIP/SVIP 双档 + 兑换码 + 开通记录） ============
    """
    CREATE TABLE IF NOT EXISTS community_member_plans(
        id TEXT PRIMARY KEY,
        level TEXT NOT NULL,
        name TEXT DEFAULT '',
        days INTEGER DEFAULT 30,
        price INTEGER DEFAULT 0,
        benefits TEXT DEFAULT '[]',
        sort INTEGER DEFAULT 0,
        active INTEGER DEFAULT 1,
        created REAL)""",
    """
    CREATE TABLE IF NOT EXISTS community_member_codes(
        code TEXT PRIMARY KEY,
        level TEXT NOT NULL,
        days INTEGER NOT NULL,
        plan_id TEXT DEFAULT '',
        batch TEXT DEFAULT '',
        used_by TEXT DEFAULT '',
        used_at REAL DEFAULT 0,
        created REAL,
        note TEXT DEFAULT '')""",
    "CREATE INDEX IF NOT EXISTS idx_mcode_used ON community_member_codes(used_by, used_at DESC)",
    """
    CREATE TABLE IF NOT EXISTS community_member_orders(
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        level TEXT NOT NULL,
        days INTEGER DEFAULT 0,
        price INTEGER DEFAULT 0,
        channel TEXT DEFAULT 'code',
        code TEXT DEFAULT '',
        contact TEXT DEFAULT '',
        note TEXT DEFAULT '',
        proof TEXT DEFAULT '',
        trade_no TEXT DEFAULT '',
        paid_at REAL DEFAULT 0,
        status INTEGER DEFAULT 1,
        created REAL,
        updated REAL)""",
    "CREATE INDEX IF NOT EXISTS idx_morder_user ON community_member_orders(user_id, created DESC)",
    "CREATE INDEX IF NOT EXISTS idx_morder_status ON community_member_orders(status, created DESC)",
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
        _migrate(c)
        _seed_boards(c)
        _seed_tasks(c)
        _seed_banner_fallback(c)
        _seed_member_plans(c)
        _seed_frames(c)
        from app_market.schema import init_app_schema
        init_app_schema(c)
        from invite_core import init_schema as init_invite_schema
        init_invite_schema(c)
        from ai_bot_schema import init_ai_bot_schema
        init_ai_bot_schema(c)
        from site_content import init_schema as init_site_schema
        init_site_schema(c)
        from handlers.app_release import init_schema as init_app_release_schema
        init_app_release_schema(c)
        from handlers.app_hot_update import init_schema as init_hot_schema
        init_hot_schema(c)
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


def _migrate(c):
    """轻量迁移：只对 community_* 表加列，幂等。"""
    # 头像框档位门槛：'' 公开 / member 会员 / svip 高级会员
    cols = [r[1] for r in c.execute("PRAGMA table_info(community_frames)").fetchall()]
    if "member_level" not in cols:
        c.execute("ALTER TABLE community_frames ADD COLUMN member_level TEXT DEFAULT ''")
    # 会员订单：补易支付字段（线上老表幂等升级）
    ocols = [r[1] for r in c.execute("PRAGMA table_info(community_member_orders)").fetchall()]
    if "proof" not in ocols:
        c.execute("ALTER TABLE community_member_orders ADD COLUMN proof TEXT DEFAULT ''")
    if "trade_no" not in ocols:
        c.execute("ALTER TABLE community_member_orders ADD COLUMN trade_no TEXT DEFAULT ''")
    if "paid_at" not in ocols:
        c.execute("ALTER TABLE community_member_orders ADD COLUMN paid_at REAL DEFAULT 0")
    # 管理端角色/模块权限（老库幂等升级）
    acols = [r[1] for r in c.execute("PRAGMA table_info(community_admins)").fetchall()]
    if "role" not in acols:
        c.execute("ALTER TABLE community_admins ADD COLUMN role TEXT DEFAULT ''")
    if "perms" not in acols:
        c.execute("ALTER TABLE community_admins ADD COLUMN perms TEXT DEFAULT ''")
    # Banner 左下角文字（老库幂等升级）
    bcols = [r[1] for r in c.execute("PRAGMA table_info(community_banners)").fetchall()]
    if "title" not in bcols:
        c.execute("ALTER TABLE community_banners ADD COLUMN title TEXT DEFAULT ''")
    # 帖子配乐/音量（老库幂等升级）
    pcols = [r[1] for r in c.execute("PRAGMA table_info(community_posts)").fetchall()]
    for col, ddl in (
        ("music", "TEXT DEFAULT ''"),
        ("audio_volume", "INTEGER DEFAULT 100"),
        ("music_volume", "INTEGER DEFAULT 50"),
        ("attachments", "TEXT DEFAULT '[]'"),
    ):
        if col not in pcols:
            c.execute("ALTER TABLE community_posts ADD COLUMN %s %s" % (col, ddl))
    # 官方通知富文本（老库幂等升级）：content 存 canonical JSON，纯文本另存。
    ocols = [r[1] for r in c.execute("PRAGMA table_info(community_official_messages)").fetchall()]
    if "content_type" not in ocols:
        c.execute("ALTER TABLE community_official_messages ADD COLUMN content_type TEXT DEFAULT 'text'")
    if "plain_text" not in ocols:
        c.execute("ALTER TABLE community_official_messages ADD COLUMN plain_text TEXT DEFAULT ''")
    # 话题创建者：用户级创建后展示「我创建的」；旧话题保持空。
    tcols = [r[1] for r in c.execute("PRAGMA table_info(community_topics)").fetchall()]
    if "created_by" not in tcols:
        c.execute("ALTER TABLE community_topics ADD COLUMN created_by TEXT DEFAULT ''")
    # 自定义表情归属：空=官方表情；非空=仅该用户收藏可见。
    ecols = [r[1] for r in c.execute("PRAGMA table_info(community_emojis)").fetchall()]
    if "owner_id" not in ecols:
        c.execute("ALTER TABLE community_emojis ADD COLUMN owner_id TEXT DEFAULT ''")
    # 旧数据里把话题名填在外链字段的 Banner 自动归位，避免点击落到任务中心。
    c.execute(
        "UPDATE community_banners SET link_type='topic'"
        " WHERE link_type='url' AND link_id IN (SELECT name FROM community_topics)")



def _seed_frames(c):
    """默认头像框（幂等：仅当表空）。image 为 media 相对路径，member_level 控制档位。"""
    if c.execute("SELECT COUNT(*) FROM community_frames").fetchone()[0]:
        return
    now = time.time()
    rows = [
        ("f01", "薄荷细环", "frames/f01_ring.png", 1, ""),
        ("f02", "双线白环", "frames/f02_double.png", 2, ""),
        ("f03", "缺口环", "frames/f03_notch.png", 3, ""),
        ("f04", "柔光薄荷", "frames/f04_glow.png", 4, "member"),
        ("f05", "星芒环", "frames/f05_star.png", 5, "member"),
        ("f06", "齿轮环", "frames/f06_gear.png", 6, "member"),
        ("f07", "波纹环", "frames/f07_ripple.png", 7, "member"),
        ("f08", "花瓣环", "frames/f08_petal.png", 8, "svip"),
        ("f09", "切角方框", "frames/f09_square.png", 9, "svip"),
        ("f10", "点阵环", "frames/f10_dots.png", 10, "svip"),
        ("f11", "藤蔓环", "frames/f11_vine.png", 11, "svip"),
        ("f12", "皇冠环", "frames/f12_crown.png", 12, "svip"),
    ]
    for fid, name, img, sort, lvl in rows:
        c.execute("INSERT OR IGNORE INTO community_frames"
                  "(id,name,image,image_dynamic,sort,active,created,member_level)"
                  " VALUES(?,?,?,?,?,?,?,?)",
                  (fid, name, img, "", sort, 1, now, lvl))


def _seed_banner_fallback(c):
    """首页无 Banner 时的默认运营卡，后台可改；仅首次写入。"""
    if c.execute("SELECT COUNT(*) FROM community_banner_fallback").fetchone()[0]:
        return
    c.execute(
        "INSERT INTO community_banner_fallback"
        "(id,enabled,title,subtitle,link_type,link_id,updated)"
        " VALUES('default',1,?,?,?,?,?)",
        ("社区活动进行中", "签到、发帖、互动都能涨经验，冲等级解锁装扮",
         "task", "", time.time()))


def _seed_member_plans(c):
    """默认套餐（幂等：仅当表空）。价格单位：分。"""
    if c.execute("SELECT COUNT(*) FROM community_member_plans").fetchone()[0]:
        return
    now = time.time()
    plans = [
        ("p_vip_1", "member", "VIP · 月卡", 30, 1200, 10),
        ("p_vip_3", "member", "VIP · 季卡", 90, 3000, 20),
        ("p_vip_12", "member", "VIP · 年卡", 365, 9800, 30),
        ("p_svip_1", "svip", "SVIP · 月卡", 30, 3000, 40),
        ("p_svip_3", "svip", "SVIP · 季卡", 90, 7800, 50),
        ("p_svip_12", "svip", "SVIP · 年卡", 365, 26800, 60),
    ]
    for pid, level, name, days, price, sort in plans:
        c.execute("INSERT INTO community_member_plans(id,level,name,days,price,benefits,sort,active,created)"
                  " VALUES(?,?,?,?,?,?,?,1,?)",
                  (pid, level, name, days, price, "[]", sort, now))
