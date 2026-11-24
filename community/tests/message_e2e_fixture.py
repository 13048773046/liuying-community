# -*- coding: utf-8 -*-
"""消息已读端到端测试的本地后端夹具。

启动一个真实 community server：
- 独立临时 SQLite 数据库（users/tokens/notifications + 社区表 + DM 私信表）
- 固定测试用户与 token
- 真实 HTTP / WebSocket 端口
- stdout 输出 READY 后由 Flutter e2e 测试接管

只用于测试，不连接线上库。
"""
import argparse
import os
import signal
import subprocess
import sys
import time
import sqlite3
import uuid

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, BASE)

ME = "e2e_me"
PEER = "e2e_peer"
OTHER = "e2e_other"
TOK_ME = "e2e-token-me"
TOK_PEER = "e2e-token-peer"
TOK_OTHER = "e2e-token-other"


def _exec(c, sql, args=()):
    c.execute(sql, args)


def build_db(path, two_convs=False):
    for suffix in ("", "-wal", "-shm"):
        try:
            os.remove(path + suffix)
        except FileNotFoundError:
            pass
    c = sqlite3.connect(path, timeout=10)
    c.execute("PRAGMA journal_mode=WAL")
    # 音乐侧共享表（与线上 users/tokens 字段保持兼容）
    c.execute("""CREATE TABLE users(
        id TEXT PRIMARY KEY, account TEXT UNIQUE, password_hash TEXT,
        name TEXT, avatar TEXT, created REAL,
        gender TEXT DEFAULT '', age INTEGER DEFAULT 0,
        background_image TEXT DEFAULT '', signature TEXT DEFAULT '',
        ip_address TEXT DEFAULT '', city TEXT DEFAULT '',
        banned INTEGER DEFAULT 0, ban_reason TEXT DEFAULT '',
        title TEXT DEFAULT '', verified TEXT DEFAULT '',
        verified_label TEXT DEFAULT '', member TEXT DEFAULT '',
        member_expire REAL DEFAULT 0, svip_expire REAL DEFAULT 0)""")
    c.execute("""CREATE TABLE tokens(
        token TEXT PRIMARY KEY, user_id TEXT, created REAL, expires REAL)""")
    c.execute("""CREATE TABLE follows(
        follower_id TEXT, following_id TEXT, created REAL,
        PRIMARY KEY(follower_id, following_id))""")
    c.execute("""CREATE TABLE notifications(
        id TEXT PRIMARY KEY, user_id TEXT, type TEXT,
        title TEXT DEFAULT '', content TEXT DEFAULT '',
        from_user_id TEXT DEFAULT '', from_user_name TEXT DEFAULT '',
        track_id TEXT DEFAULT '', track_title TEXT DEFAULT '',
        is_read INTEGER DEFAULT 0, created REAL,
        comment_id TEXT DEFAULT '', is_deleted INTEGER DEFAULT 0)""")
    c.execute("CREATE INDEX idx_notif_user ON notifications(user_id, created DESC)")
    c.execute("""CREATE TABLE community_dm_messages(
        id TEXT PRIMARY KEY, conv_id TEXT NOT NULL,
        sender_id TEXT NOT NULL, receiver_id TEXT NOT NULL,
        content TEXT DEFAULT '', created REAL,
        is_read INTEGER DEFAULT 0, msg_type TEXT DEFAULT 'text')""")
    c.execute("CREATE INDEX idx_dm_msg_conv ON community_dm_messages(conv_id, created)")
    c.execute("CREATE INDEX idx_dm_msg_receiver ON community_dm_messages(receiver_id, is_read)")

    now = time.time()
    for uid, name in ((ME, "端到端我"), (PEER, "端到端对方"), (OTHER, "端到端路人")):
        _exec(c, "INSERT INTO users(id,account,password_hash,name,avatar,created,title,verified,verified_label)"
               " VALUES(?,?,?,?,?,?,?,?,?)",
               (uid, uid, "x", name, "", now, "测试头衔", "1", "官方认证"))
    for tok, uid in ((TOK_ME, ME), (TOK_PEER, PEER), (TOK_OTHER, OTHER)):
        _exec(c, "INSERT INTO tokens(token,user_id,created,expires) VALUES(?,?,?,?)",
               (tok, uid, now, now + 3600 * 24))
    _exec(c, "INSERT INTO follows(follower_id,following_id,created) VALUES(?,?,?)", (ME, PEER, now))
    _exec(c, "INSERT INTO follows(follower_id,following_id,created) VALUES(?,?,?)", (PEER, ME, now))

    # 先释放共享表连接，再让 schema 独立连接建社区表，避免 database is locked
    c.commit()
    c.close()
    os.environ["COMMUNITY_DB"] = path
    from schema import init_schema
    init_schema()
    c = sqlite3.connect(path, timeout=10)
    c.execute("PRAGMA journal_mode=WAL")
    # 线上 schema 迁移列；测试库按最新 DM 契约补齐
    try:
        c.execute("ALTER TABLE community_conversations ADD COLUMN last_type TEXT DEFAULT 'text'")
    except sqlite3.OperationalError:
        pass

    # 管理端超管令牌（仅测试库），用于真实走审核接口产生 community_audit WS 通知
    _exec(c, "INSERT OR REPLACE INTO community_admins(token,user_id,level,role,perms,name,created)"
           " VALUES(?,?,?,?,?,?,?)",
           ("e2e-admin-token", ME, 1, "super", "", "端到端管理员", now))

    # 互动通知：4 未读 + 1 已读，覆盖 like/comment/follow/audit
    def notif(nid, ntype, title, content, read, offset):
        _exec(c, "INSERT INTO notifications(id,user_id,type,title,content,from_user_id,"
                "from_user_name,is_read,created,is_deleted) VALUES(?,?,?,?,?,?,?,?,?,0)",
               (nid, ME, ntype, title, content, PEER, "端到端对方", read, now - offset))
    notif("n_like_unread", "community_like", "收到新点赞", "赞了你的帖子", 0, 10)
    notif("n_like_read", "community_like", "收到新点赞", "赞了你的旧帖子", 1, 20)
    notif("n_comment_unread", "community_comment", "收到新评论", "写得真好", 0, 30)
    notif("n_interact_unread", "community_interact", "新增关注", "关注了你", 0, 40)
    notif("n_audit_unread", "community_audit", "审核通过", "你的帖子已通过审核", 0, 50)

    # 官方通知独立表：2 条未读
    _exec(c, "INSERT INTO community_official_messages(id,content,sender_name,receiver_user_id,created)"
           " VALUES(?,?,?,?,?)", ("o1", "欢迎来到流萤社区", "流萤社区官方", "", now - 100))
    _exec(c, "INSERT INTO community_official_messages(id,content,sender_name,receiver_user_id,created)"
           " VALUES(?,?,?,?,?)", ("o2", "社区规范已更新", "流萤社区官方", "", now - 90))

    # 私信：3 条对方发来的未读 + 己方 1 条已读 / 1 条未读
    conv = "_".join(sorted((ME, PEER)))
    _exec(c, "INSERT INTO community_conversations(id,user_a,user_b,last_msg,last_type,last_time,"
           "unread_a,unread_b,created) VALUES(?,?,?,?,?,?,?,?,?)",
           (conv, min(ME, PEER), max(ME, PEER), "晚上一起听歌吗", "text", now - 10, 3, 0, now - 1000))
    def dm(mid, sender, receiver, content, read, offset, mtype="text"):
        _exec(c, "INSERT INTO community_dm_messages(id,conv_id,sender_id,receiver_id,content,created,is_read,msg_type)"
               " VALUES(?,?,?,?,?,?,?,?)",
               (mid, conv, sender, receiver, content, now - offset, read, mtype))
    dm("m_in1", PEER, ME, "在吗", 0, 300)
    dm("m_in2", PEER, ME, "晚上一起听歌吗", 0, 30)
    dm("m_in3", PEER, ME, "我把歌单整理好了", 0, 10)
    dm("m_out_read", ME, PEER, "好啊", 1, 400)
    dm("m_out_unread", ME, PEER, "那我等你", 0, 20)
    # 可选：第二个会话（已读）仅给“列表本地置顶”专项测试使用，
    # 默认不插入，避免影响既有“已读”文案数量断言。
    if two_convs:
        conv2 = "_".join(sorted((ME, OTHER)))
        _exec(c, "INSERT INTO community_conversations(id,user_a,user_b,last_msg,last_type,last_time,"
               "unread_a,unread_b,created) VALUES(?,?,?,?,?,?,?,?,?)",
               (conv2, min(ME, OTHER), max(ME, OTHER), "稍后聊", "text", now - 5, 0, 0, now - 900))

    c.commit()
    c.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", required=True)
    parser.add_argument("--port", type=int, default=8795)
    parser.add_argument("--two-convs", action="store_true",
                        help="额外插入一个已读会话，用于列表置顶实时测试")
    args = parser.parse_args()
    build_db(args.db, two_convs=args.two_convs)
    env = dict(os.environ)
    env["COMMUNITY_DB"] = args.db
    env["COMMUNITY_HOST"] = "127.0.0.1"
    env["COMMUNITY_PORT"] = str(args.port)
    proc = subprocess.Popen(
        [sys.executable, os.path.join(BASE, "server.py")],
        env=env, cwd=BASE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    # 等端口可用再宣告 READY，避免测试抢跑
    import socket
    deadline = time.time() + 15
    while time.time() < deadline:
        if proc.poll() is not None:
            err = proc.stderr.read().decode("utf-8", "ignore") if proc.stderr else ""
            print("SERVER_FAILED\n" + err, flush=True)
            sys.exit(1)
        try:
            with socket.create_connection(("127.0.0.1", args.port), timeout=0.5):
                break
        except OSError:
            time.sleep(0.1)
    else:
        proc.terminate()
        print("SERVER_TIMEOUT", flush=True)
        sys.exit(1)
    print("READY %d" % args.port, flush=True)

    def _stop(*_):
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
        sys.exit(0)
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    try:
        proc.wait()
    finally:
        if proc.poll() is None:
            proc.kill()


if __name__ == "__main__":
    main()
