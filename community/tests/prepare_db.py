# -*- coding: utf-8 -*-
"""测试环境准备：创建音乐最小共享表（模拟线上 tracks.db 的音乐侧）+ 测试账号/令牌/管理员。

注意：本脚本仅用于本地测试，部署环境直接连线上 tracks.db（表已存在）。
"""
import os
import sys
import time
import uuid
import sqlite3
import secrets

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, BASE)

TEST_DB = os.path.join(BASE, "tests", "tracks_test.db")
os.environ["COMMUNITY_DB"] = TEST_DB


def make_db():
    """建音乐最小共享表（users/tokens/follows/notifications）+ 社区表。"""
    if os.path.exists(TEST_DB):
        os.remove(TEST_DB)
    for suf in ("-wal", "-shm"):
        p = TEST_DB + suf
        if os.path.exists(p):
            os.remove(p)
    c = sqlite3.connect(TEST_DB, timeout=10)
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("""CREATE TABLE IF NOT EXISTS users(
        id TEXT PRIMARY KEY, account TEXT UNIQUE, password_hash TEXT,
        name TEXT, avatar TEXT, created REAL,
        gender TEXT DEFAULT '', age INTEGER DEFAULT 0,
        background_image TEXT DEFAULT '', signature TEXT DEFAULT '',
        ip_address TEXT DEFAULT '', city TEXT DEFAULT '',
        banned INTEGER DEFAULT 0, ban_reason TEXT DEFAULT '',
        title TEXT DEFAULT '', verified TEXT DEFAULT '',
        verified_label TEXT DEFAULT '', member TEXT DEFAULT '',
        member_expire REAL DEFAULT 0, svip_expire REAL DEFAULT 0)""")
    c.execute("""CREATE TABLE IF NOT EXISTS tokens(
        token TEXT PRIMARY KEY, user_id TEXT, created REAL, expires REAL)""")
    c.execute("""CREATE TABLE IF NOT EXISTS follows(
        follower_id TEXT, following_id TEXT, created REAL,
        PRIMARY KEY(follower_id, following_id))""")
    c.execute("""CREATE TABLE IF NOT EXISTS notifications(
        id TEXT PRIMARY KEY, user_id TEXT, type TEXT,
        title TEXT DEFAULT '', content TEXT DEFAULT '',
        from_user_id TEXT DEFAULT '', from_user_name TEXT DEFAULT '',
        track_id TEXT DEFAULT '', track_title TEXT DEFAULT '',
        is_read INTEGER DEFAULT 0, created REAL,
        comment_id TEXT DEFAULT '', is_deleted INTEGER DEFAULT 0)""")
    c.execute("CREATE INDEX IF NOT EXISTS idx_notif_user ON notifications(user_id, created DESC)")
    c.commit()
    c.close()
    # 社区表
    from schema import init_schema
    init_schema()
    return TEST_DB


def seed():
    """造测试用户 + token + 一级管理员。"""
    c = sqlite3.connect(TEST_DB, timeout=10)
    now = time.time()
    users = []
    for i in range(3):
        uid = uuid.uuid4().hex
        c.execute("INSERT INTO users(id,account,password_hash,name,avatar,created,signature,title)"
                  " VALUES(?,?,?,?,?,?,?,?)",
                  (uid, "10000%d" % (i + 1), "x", "测试用户%d" % (i + 1), "", now,
                   "流萤社区测试账号%d" % (i + 1), "测试头衔" if i == 0 else ""))
        users.append(uid)
    # token
    tokens = []
    for uid in users:
        tok = secrets.token_urlsafe(32)
        c.execute("INSERT INTO tokens(token,user_id,created,expires) VALUES(?,?,?,?)",
                  (tok, uid, now, now + 3600 * 24))
        tokens.append(tok)
    # 一级管理员（用户1）
    adm_tok = secrets.token_urlsafe(24)
    c.execute("INSERT INTO community_admins(token,user_id,level,name,created) VALUES(?,?,?,?,?)",
              (adm_tok, users[0], 1, "一级管理员", now))
    # 用户2 关注用户1（关注流测试）
    c.execute("INSERT INTO follows(follower_id,following_id,created) VALUES(?,?,?)",
              (users[1], users[0], now))
    c.commit()
    c.close()
    return users, tokens, adm_tok


if __name__ == "__main__":
    make_db()
    u, t, a = seed()
    print("TEST_DB:", TEST_DB)
    print("users:", u)
    print("tokens:", t)
    print("admin_token:", a)
