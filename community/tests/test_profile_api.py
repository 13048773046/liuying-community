# -*- coding: utf-8 -*-
"""资料编辑闭环：昵称/签名、头像上传到共享媒体目录、邮箱验证码改绑。"""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request
import urllib.error
import uuid

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BASE not in sys.path:
    sys.path.insert(0, BASE)

PORT = 8803


def _build_db(path):
    c = sqlite3.connect(path, timeout=10)
    c.executescript("""
        CREATE TABLE users(
          id TEXT PRIMARY KEY, account TEXT UNIQUE, password_hash TEXT,
          name TEXT, avatar TEXT, created REAL,
          gender TEXT DEFAULT '', age INTEGER DEFAULT 0,
          background_image TEXT DEFAULT '', signature TEXT DEFAULT '',
          ip_address TEXT DEFAULT '', city TEXT DEFAULT '',
          banned INTEGER DEFAULT 0, ban_reason TEXT DEFAULT '',
          title TEXT DEFAULT '', verified TEXT DEFAULT '',
          verified_label TEXT DEFAULT '', member TEXT DEFAULT '',
          member_expire REAL DEFAULT 0, svip_expire REAL DEFAULT 0,
          email TEXT DEFAULT '', email_verified INTEGER DEFAULT 0);
        CREATE TABLE tokens(token TEXT PRIMARY KEY, user_id TEXT, created REAL, expires REAL);
        CREATE TABLE follows(follower_id TEXT, following_id TEXT, created REAL);
        CREATE TABLE notifications(id TEXT PRIMARY KEY, user_id TEXT, type TEXT,
          title TEXT, content TEXT, from_user_id TEXT, from_user_name TEXT,
          track_id TEXT, track_title TEXT, is_read INTEGER, created REAL,
          comment_id TEXT, is_deleted INTEGER);
        CREATE TABLE email_codes(email TEXT PRIMARY KEY, code TEXT NOT NULL,
          created REAL NOT NULL, last_sent REAL NOT NULL,
          fail_count INTEGER DEFAULT 0, day_count INTEGER DEFAULT 0,
          day_date TEXT DEFAULT '');
    """)
    now = time.time()
    c.execute("""INSERT INTO users(id,account,password_hash,name,avatar,created,
                 email,email_verified,ip_address)
                 VALUES(?,?,?,?,?,?,?,?,?)""",
              ("u1", "200001", "x", "资料用户", "", now, "profile@example.com", 1, "127.0.0.1"))
    c.execute("INSERT INTO tokens(token,user_id,created,expires) VALUES(?,?,?,?)",
              ("profile-token", "u1", now, now + 3600))
    c.commit()
    c.close()
    os.environ["COMMUNITY_DB"] = path
    import schema
    schema.DB_PATH = path
    schema.FILES_DIR = os.path.join(os.path.dirname(path), "files")
    schema.init_schema()


class ProfileApiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="community_profile_")
        cls.db = os.path.join(cls.tmp, "profile.db")
        cls.music_files = os.path.join(cls.tmp, "music_files")
        os.makedirs(cls.music_files)
        _build_db(cls.db)
        env = dict(os.environ)
        env.update({
            "COMMUNITY_DB": cls.db,
            "COMMUNITY_PORT": str(PORT),
            "COMMUNITY_HOST": "127.0.0.1",
            "COMMUNITY_MUSIC_FILES": cls.music_files,
            "COMMUNITY_SMTP_CONFIG": os.path.join(cls.tmp, "no-smtp.json"),
            "COMMUNITY_LOG_JSON": "false",
        })
        cls.proc = subprocess.Popen(
            [sys.executable, os.path.join(BASE, "server.py")],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(40):
            try:
                with urllib.request.urlopen("http://127.0.0.1:%d/health" % PORT, timeout=1) as r:
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

    def _req(self, method, path, body=None, token=None, raw_body=None, ctype=None):
        headers = {}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        elif raw_body is not None:
            data = raw_body
            headers["Content-Type"] = ctype
        if token:
            headers["Authorization"] = "Bearer " + token
        req = urllib.request.Request(
            "http://127.0.0.1:%d/community/api%s" % (PORT, path),
            data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode())

    def test_update_basic_profile(self):
        st, body = self._req("POST", "/user/me", {
            "name": "新昵称", "signature": "新签名", "gender": "女",
            "age": 23, "city": "苏州",
        }, token="profile-token")
        self.assertEqual(st, 200)
        self.assertEqual(body["user"]["name"], "新昵称")
        self.assertEqual(body["user"]["city"], "苏州")

    def test_avatar_upload_writes_shared_media_and_user(self):
        boundary = "----profile" + uuid.uuid4().hex
        data = (b"--" + boundary.encode() + b"\r\n"
                b'Content-Disposition: form-data; name="avatar"; filename="a.jpg"\r\n'
                b"Content-Type: image/jpeg\r\n\r\n"
                b"\xff\xd8\xff\xe0avatar" + b"\r\n"
                b"--" + boundary.encode() + b"--\r\n")
        st, body = self._req("POST", "/user/me/avatar", raw_body=data,
                             ctype="multipart/form-data; boundary=" + boundary,
                             token="profile-token")
        self.assertEqual(st, 200)
        self.assertEqual(body["avatar"], "u1_avatar.jpg")
        self.assertTrue(os.path.exists(os.path.join(self.music_files, "u1_avatar.jpg")))
        c = sqlite3.connect(self.db)
        avatar = c.execute("SELECT avatar FROM users WHERE id='u1'").fetchone()[0]
        c.close()
        self.assertEqual(avatar, "u1_avatar.jpg")

    def test_me_returns_bound_phone_mask(self):
        c = sqlite3.connect(self.db)
        c.execute("""INSERT OR REPLACE INTO community_invite_profiles
                     (user_id,code,phone_hash,phone_mask,phone_verified_at,created,updated)
                     VALUES(?,?,?,?,?,?,?)""",
                  ("u1", "ME001", "hash-me-001", "138****8000", time.time(),
                   time.time(), time.time()))
        c.commit()
        c.close()
        st, body = self._req("GET", "/user/me", token="profile-token")
        self.assertEqual(st, 200)
        self.assertEqual(body["user"]["phoneMask"], "138****8000")
        self.assertTrue(body["user"]["phoneVerified"])

    def test_update_email_with_code(self):
        email = "changed@example.com"
        code = "135790"
        c = sqlite3.connect(self.db)
        c.execute("""INSERT OR REPLACE INTO email_codes
                     (email,code,created,last_sent,fail_count,day_count,day_date)
                     VALUES(?,?,?,?,0,1,date('now'))""",
                  (email, code, time.time(), time.time()))
        c.commit()
        c.close()
        st, body = self._req("POST", "/user/me",
                             {"name": "资料用户", "email": email, "code": code},
                             token="profile-token")
        self.assertEqual(st, 200)
        self.assertEqual(body["user"]["email"], email)
        c = sqlite3.connect(self.db)
        row = c.execute("SELECT email,email_verified FROM users WHERE id='u1'").fetchone()
        c.close()
        self.assertEqual(row[0], email)
        self.assertEqual(row[1], 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
