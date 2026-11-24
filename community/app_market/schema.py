# -*- coding: utf-8 -*-
"""应用市场域独立 Schema：只创建 community_app_* 表，不修改现有社区/音乐表。"""
import time

APP_TABLES = [
    """
    CREATE TABLE IF NOT EXISTS community_app_categories(
        id TEXT PRIMARY KEY,
        parent_id TEXT DEFAULT '',
        name TEXT NOT NULL,
        slug TEXT NOT NULL UNIQUE,
        sort INTEGER DEFAULT 0,
        active INTEGER DEFAULT 1,
        created REAL)""",
    "CREATE INDEX IF NOT EXISTS idx_cappcat_parent ON community_app_categories(parent_id, sort, created)",
    """
    CREATE TABLE IF NOT EXISTS community_apps(
        id TEXT PRIMARY KEY,
        submitter_id TEXT NOT NULL,
        name TEXT NOT NULL,
        icon TEXT DEFAULT '',
        platform TEXT NOT NULL,
        package_type TEXT NOT NULL,
        package_name TEXT NOT NULL,
        category_id TEXT NOT NULL,
        subcategory_id TEXT NOT NULL,
        description TEXT DEFAULT '',
        share_reason TEXT DEFAULT '',
        status INTEGER DEFAULT 0,
        featured INTEGER DEFAULT 0,
        download_count INTEGER DEFAULT 0,
        view_count INTEGER DEFAULT 0,
        rating_count INTEGER DEFAULT 0,
        rating_sum INTEGER DEFAULT 0,
        favorite_count INTEGER DEFAULT 0,
        comment_count INTEGER DEFAULT 0,
        current_version_id TEXT DEFAULT '',
        created REAL,
        updated REAL,
        published_at REAL)""",
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_capp_pkg ON community_apps(platform, package_name)",
    "CREATE INDEX IF NOT EXISTS idx_capp_status ON community_apps(status, created DESC)",
    "CREATE INDEX IF NOT EXISTS idx_capp_cat ON community_apps(category_id, subcategory_id, status, created DESC)",
    "CREATE INDEX IF NOT EXISTS idx_capp_submitter ON community_apps(submitter_id, created DESC)",
    """
    CREATE TABLE IF NOT EXISTS community_app_versions(
        id TEXT PRIMARY KEY,
        app_id TEXT NOT NULL,
        version_name TEXT NOT NULL,
        os_version TEXT DEFAULT '',
        download_url TEXT NOT NULL,
        provider TEXT DEFAULT 'auto',
        share_code TEXT DEFAULT '',
        screenshots TEXT DEFAULT '[]',
        status INTEGER DEFAULT 0,
        reject_reason TEXT DEFAULT '',
        resolved_url TEXT DEFAULT '',
        resolved_at REAL DEFAULT 0,
        resolved_expires REAL DEFAULT 0,
        file_name TEXT DEFAULT '',
        file_size INTEGER DEFAULT 0,
        content_type TEXT DEFAULT '',
        supports_range INTEGER DEFAULT 0,
        last_resolve_error TEXT DEFAULT '',
        created REAL,
        approved_at REAL,
        updated REAL)""",
    "CREATE INDEX IF NOT EXISTS idx_cappver_app ON community_app_versions(app_id, created DESC)",
    "CREATE INDEX IF NOT EXISTS idx_cappver_status ON community_app_versions(status, created DESC)",
    """
    CREATE TABLE IF NOT EXISTS community_app_comments(
        id TEXT PRIMARY KEY,
        app_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        parent_id TEXT DEFAULT '',
        content TEXT DEFAULT '',
        like_count INTEGER DEFAULT 0,
        status INTEGER DEFAULT 1,
        created REAL)""",
    "CREATE INDEX IF NOT EXISTS idx_cappcomment_app ON community_app_comments(app_id, status, created DESC)",
    "CREATE INDEX IF NOT EXISTS idx_cappcomment_user ON community_app_comments(user_id, created DESC)",
    """
    CREATE TABLE IF NOT EXISTS community_app_ratings(
        user_id TEXT NOT NULL,
        app_id TEXT NOT NULL,
        score INTEGER NOT NULL,
        created REAL,
        updated REAL,
        PRIMARY KEY(user_id, app_id))""",
    "CREATE INDEX IF NOT EXISTS idx_capprating_app ON community_app_ratings(app_id, updated DESC)",
    """
    CREATE TABLE IF NOT EXISTS community_app_favorites(
        user_id TEXT NOT NULL,
        app_id TEXT NOT NULL,
        created REAL,
        PRIMARY KEY(user_id, app_id))""",
    "CREATE INDEX IF NOT EXISTS idx_cappfav_user ON community_app_favorites(user_id, created DESC)",
    "CREATE INDEX IF NOT EXISTS idx_cappfav_app ON community_app_favorites(app_id, created DESC)",
    """
    CREATE TABLE IF NOT EXISTS community_app_behavior_events(
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        app_id TEXT NOT NULL,
        event TEXT NOT NULL,
        value REAL DEFAULT 1.0,
        meta TEXT DEFAULT '',
        created REAL)""",
    "CREATE INDEX IF NOT EXISTS idx_cappbeh_user ON community_app_behavior_events(user_id, created DESC)",
    "CREATE INDEX IF NOT EXISTS idx_cappbeh_app ON community_app_behavior_events(app_id, event, created DESC)",
    """
    CREATE TABLE IF NOT EXISTS community_app_recommend_push(
        uid TEXT NOT NULL,
        app_id TEXT NOT NULL,
        pushed_at REAL NOT NULL,
        PRIMARY KEY(uid, app_id))""",
    "CREATE INDEX IF NOT EXISTS idx_capppush_uid ON community_app_recommend_push(uid, pushed_at DESC)",
]

# 大类用固定 ID，子分类 parent_id 指向大类；管理员可在后台增删改。
APP_CATEGORY_SEED = [
    ("appcat_tools", "", "工具", "tools", 0),
    ("appcat_tools_system", "appcat_tools", "系统工具", "tools-system", 1),
    ("appcat_tools_file", "appcat_tools", "文件管理", "tools-file", 2),
    ("appcat_tools_download", "appcat_tools", "下载工具", "tools-download", 3),
    ("appcat_tools_security", "appcat_tools", "安全防护", "tools-security", 4),
    ("appcat_efficiency", "", "效率", "efficiency", 10),
    ("appcat_efficiency_note", "appcat_efficiency", "笔记", "efficiency-note", 1),
    ("appcat_efficiency_todo", "appcat_efficiency", "待办", "efficiency-todo", 2),
    ("appcat_efficiency_calendar", "appcat_efficiency", "日历", "efficiency-calendar", 3),
    ("appcat_efficiency_input", "appcat_efficiency", "输入法", "efficiency-input", 4),
    ("appcat_social", "", "社交", "social", 20),
    ("appcat_social_chat", "appcat_social", "通讯", "social-chat", 1),
    ("appcat_social_community", "appcat_social", "社区", "social-community", 2),
    ("appcat_social_friend", "appcat_social", "交友", "social-friend", 3),
    ("appcat_social_mail", "appcat_social", "邮箱", "social-mail", 4),
    ("appcat_media", "", "影音", "media", 30),
    ("appcat_media_music", "appcat_media", "音乐", "media-music", 1),
    ("appcat_media_video", "appcat_media", "视频", "media-video", 2),
    ("appcat_media_player", "appcat_media", "播放器", "media-player", 3),
    ("appcat_media_live", "appcat_media", "直播", "media-live", 4),
    ("appcat_game", "", "游戏", "game", 40),
    ("appcat_game_casual", "appcat_game", "休闲", "game-casual", 1),
    ("appcat_game_rpg", "appcat_game", "角色扮演", "game-rpg", 2),
    ("appcat_game_strategy", "appcat_game", "策略", "game-strategy", 3),
    ("appcat_game_sim", "appcat_game", "模拟", "game-sim", 4),
    ("appcat_photo", "", "摄影", "photo", 50),
    ("appcat_photo_camera", "appcat_photo", "相机", "photo-camera", 1),
    ("appcat_photo_edit", "appcat_photo", "修图", "photo-edit", 2),
    ("appcat_photo_clip", "appcat_photo", "剪辑", "photo-clip", 3),
    ("appcat_photo_gallery", "appcat_photo", "图库", "photo-gallery", 4),
    ("appcat_study", "", "学习", "study", 60),
    ("appcat_study_language", "appcat_study", "语言", "study-language", 1),
    ("appcat_study_read", "appcat_study", "阅读", "study-read", 2),
    ("appcat_study_course", "appcat_study", "课程", "study-course", 3),
    ("appcat_study_exam", "appcat_study", "题库", "study-exam", 4),
    ("appcat_life", "", "生活", "life", 70),
    ("appcat_life_weather", "appcat_life", "天气", "life-weather", 1),
    ("appcat_life_travel", "appcat_life", "出行", "life-travel", 2),
    ("appcat_life_shop", "appcat_life", "购物", "life-shop", 3),
    ("appcat_life_health", "appcat_life", "健康", "life-health", 4),
    ("appcat_dev", "", "开发", "dev", 80),
    ("appcat_dev_code", "appcat_dev", "编程", "dev-code", 1),
    ("appcat_dev_debug", "appcat_dev", "调试", "dev-debug", 2),
    ("appcat_dev_server", "appcat_dev", "服务器", "dev-server", 3),
    ("appcat_dev_design", "appcat_dev", "设计", "dev-design", 4),
    ("appcat_other", "", "其他", "other", 90),
    ("appcat_other_tool", "appcat_other", "实用工具", "other-tool", 1),
    ("appcat_other_misc", "appcat_other", "其他", "other-misc", 2),
]


def init_app_schema(c):
    """幂等建表 + 分类种子。由主 schema.init_schema() 调用。"""
    for ddl in APP_TABLES:
        c.execute(ddl)
    now = time.time()
    for cid, parent, name, slug, sort in APP_CATEGORY_SEED:
        c.execute(
            "INSERT OR IGNORE INTO community_app_categories"
            "(id,parent_id,name,slug,sort,active,created) VALUES(?,?,?,?,?,1,?)",
            (cid, parent, name, slug, sort, now))
    # 已有 admin 角色（非审核员）默认获得应用市场模块权限；审核员仍需后台单独勾选。
    try:
        for token, level, role, perms in c.execute(
                "SELECT token,level,COALESCE(role,''),COALESCE(perms,'') FROM community_admins").fetchall():
            r = (role or "").strip()
            if r not in ("super", "admin") and (level or 2) != 1:
                continue
            plist = [x for x in (perms or "").split(",") if x]
            if "apps" not in plist:
                plist.append("apps")
                c.execute("UPDATE community_admins SET perms=? WHERE token=?", (",".join(plist), token))
    except Exception:
        pass
