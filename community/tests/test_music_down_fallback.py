# -*- coding: utf-8 -*-
"""音乐停服隔离验证：社区登录兜底 + 曲库直读兜底。

用真实 server 进程、真实 HTTP、临时 SQLite；音乐 API 指向不可达端口，
断言社区仍能登录并拿到曲库列表。
"""
import hashlib
import json
import os
import secrets
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BASE not in sys.path:
    sys.path.insert(0, BASE)

PORT = 8798
PASSWORD = "test-pass-123"


def _hash(pw):
    salt = secrets.token_hex(16)
    iters = 210000
    digest = hashlib.pbkdf2_hmac(
        "sha256", pw.encode("utf-8"), bytes.fromhex(salt), iters).hex()
    return "%s$%d$%s" % (salt, iters, digest)


def _build_db(path):
    c = sqlite3.connect(path, timeout=10)
    c.executescript("""
        CREATE TABLE users(
          id TEXT PRIMARY KEY, account TEXT UNIQUE, password_hash TEXT,
          name TEXT, avatar TEXT, created REAL, gender TEXT DEFAULT '',
          age INTEGER DEFAULT 0, background_image TEXT DEFAULT '',
          signature TEXT DEFAULT '', ip_address TEXT DEFAULT '',
          city TEXT DEFAULT '', banned INTEGER DEFAULT 0, ban_reason TEXT DEFAULT '',
          title TEXT DEFAULT '', verified TEXT DEFAULT '', verified_label TEXT DEFAULT '',
          member TEXT DEFAULT '', member_expire REAL DEFAULT 0, svip_expire REAL DEFAULT 0,
          email TEXT DEFAULT '');
        CREATE TABLE tokens(token TEXT PRIMARY KEY, user_id TEXT, created REAL, expires REAL);
        CREATE TABLE follows(follower_id TEXT, following_id TEXT, created REAL,
          PRIMARY KEY(follower_id, following_id));
        CREATE TABLE notifications(id TEXT PRIMARY KEY, user_id TEXT, type TEXT,
          title TEXT DEFAULT '', content TEXT DEFAULT '', from_user_id TEXT DEFAULT '',
          from_user_name TEXT DEFAULT '', track_id TEXT DEFAULT '', track_title TEXT DEFAULT '',
          is_read INTEGER DEFAULT 0, created REAL, comment_id TEXT DEFAULT '',
          is_deleted INTEGER DEFAULT 0);
        CREATE TABLE tracks(id TEXT PRIMARY KEY, title TEXT, artist TEXT, album TEXT,
          cover TEXT, fname TEXT, size INTEGER, dur REAL, created REAL,
          play_count INTEGER DEFAULT 0, like_count INTEGER DEFAULT 0,
          share_count INTEGER DEFAULT 0, user_id TEXT, lrc TEXT, offline INTEGER DEFAULT 0);
        CREATE TABLE comments(id TEXT PRIMARY KEY, track_id TEXT);
    """)
    now = time.time()
    c.execute("""INSERT INTO users(id,account,password_hash,name,avatar,created,email)
                 VALUES(?,?,?,?,?,?,?)""",
              ("fallback_u", "fallback", _hash(PASSWORD), "兜底用户", "", now,
               "fallback@example.com"))
    c.execute("""INSERT INTO tracks(id,title,artist,album,cover,fname,size,dur,created,
                 play_count,like_count,share_count,user_id,lrc,offline)
                 VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
              ("tr1", "停服也能听", "流小萤", "兜底专辑", "cover.jpg", "a.mp3",
               1000, 61.5, now, 3, 2, 1, "fallback_u", "", 0))
    c.commit()
    c.close()
    os.environ["COMMUNITY_DB"] = path
    import schema
    schema.DB_PATH = path
    schema.FILES_DIR = os.path.join(os.path.dirname(path), 'files')
    schema.init_schema()


class MusicDownFallbackTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="community_music_down_")
        cls.db = os.path.join(cls.tmp, "fallback.db")
        _build_db(cls.db)
        env = dict(os.environ)
        env.update({
            "COMMUNITY_DB": cls.db,
            "COMMUNITY_PORT": str(PORT),
            "COMMUNITY_HOST": "127.0.0.1",
            "COMMUNITY_LOG_JSON": "false",
            # 模拟音乐进程停止：代理目标不可达
            "COMMUNITY_MUSIC_API": "http://127.0.0.1:9",
        })
        cls.proc = subprocess.Popen(
            [sys.executable, os.path.join(BASE, "server.py")],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(40):
            try:
                with urllib.request.urlopen(
                        "http://127.0.0.1:%d/health" % PORT, timeout=1) as r:
                    if r.status == 200:
                        return
            except Exception:
                time.sleep(0.25)
        raise RuntimeError("server did not start")

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        try:
            cls.proc.wait(timeout=5)
        except Exception:
            cls.proc.kill()

    def _post(self, path, body, headers=None):
        req = urllib.request.Request(
            "http://127.0.0.1:%d%s" % (PORT, path),
            data=json.dumps(body).encode(), method="POST",
            headers={"Content-Type": "application/json", **(headers or {})})
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode())

    def test_login_works_when_music_down(self):
        st, body = self._post("/community/api/auth/login",
                             {"account": "fallback", "password": PASSWORD})
        self.assertEqual(st, 200, body)
        self.assertTrue(body.get("token"))
        self.assertEqual(body.get("id"), "fallback_u")
        # token 立即可用于社区鉴权
        req = urllib.request.Request(
            "http://127.0.0.1:%d/community/api/user/me" % PORT,
            headers={"Authorization": "Bearer " + body["token"]})
        with urllib.request.urlopen(req, timeout=5) as r:
            self.assertEqual(r.status, 200)

    def test_login_wrong_password_is_401(self):
        st, body = self._post("/community/api/auth/login",
                             {"account": "fallback", "password": "bad"})
        self.assertEqual(st, 401)
        self.assertIn("账号或密码错误", body.get("error", ""))

    def test_tracks_fall_back_to_local_db(self):
        with urllib.request.urlopen(
                "http://127.0.0.1:%d/community/api/music/tracks?limit=2" % PORT,
                timeout=8) as r:
            self.assertEqual(r.status, 200)
            body = json.loads(r.read().decode())
        self.assertEqual(body["total"], 1)
        self.assertEqual(body["list"][0]["title"], "停服也能听")
        self.assertIn("/community/api/music/cover/tr1", body["list"][0]["cover"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
