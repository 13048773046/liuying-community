# -*- coding: utf-8 -*-
"""邮箱验证码登录/自动注册：社区自有接口，不依赖音乐进程。"""
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

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BASE not in sys.path:
    sys.path.insert(0, BASE)

PORT = 8802


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
              ("old1", "200001", "x", "老邮箱用户", "", now, "old@example.com", 1, "127.0.0.1"))
    c.commit()
    c.close()
    os.environ["COMMUNITY_DB"] = path
    import schema
    schema.DB_PATH = path
    schema.FILES_DIR = os.path.join(os.path.dirname(path), "files")
    schema.init_schema()


class EmailLoginTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="community_email_login_")
        cls.db = os.path.join(cls.tmp, "email.db")
        _build_db(cls.db)
        env = dict(os.environ)
        env.update({
            "COMMUNITY_DB": cls.db,
            "COMMUNITY_PORT": str(PORT),
            "COMMUNITY_HOST": "127.0.0.1",
            "COMMUNITY_CAPTCHA_DEBUG": "1",
            "COMMUNITY_CAPTCHA_LEGACY": "1",
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

    def _post(self, path, body):
        req = urllib.request.Request(
            "http://127.0.0.1:%d/community/api%s" % (PORT, path),
            data=json.dumps(body).encode(), method="POST",
            headers={"Content-Type": "application/json", "User-Agent": "Dart/3.0 (dart:io)"})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode())

    def _captcha_raw(self):
        url = "http://127.0.0.1:%d/community/api/captcha" % PORT
        with urllib.request.urlopen(url, timeout=10) as r:
            return json.loads(r.read().decode())

    def _captcha(self):
        body = self._captcha_raw()
        return {"captcha_id": body["id"], "captcha_x": body["debug_x"], "captcha_y": body["debug_y"]}

    def _put_code(self, email, code, created=None):
        c = sqlite3.connect(self.db, timeout=10)
        now = time.time() if created is None else created
        c.execute("""INSERT OR REPLACE INTO email_codes
                     (email,code,created,last_sent,fail_count,day_count,day_date)
                     VALUES(?,?,?,?,0,1,date('now'))""",
                  (email, code, now, now))
        c.commit()
        c.close()

    def _user(self, email):
        c = sqlite3.connect(self.db, timeout=10)
        row = c.execute("SELECT id,account,name,email FROM users WHERE email=?", (email,)).fetchone()
        c.close()
        return row

    def test_existing_email_logs_in_without_new_user(self):
        self._put_code("old@example.com", "123456")
        st, body = self._post("/auth/login-email",
                              {"email": "old@example.com", "code": "123456"})
        self.assertEqual(st, 200)
        self.assertEqual(body.get("id"), "old1")
        self.assertTrue(body.get("token"))
        self.assertEqual(self._user("old@example.com")[1], "200001")

    def test_new_email_auto_registers_and_reuses_account(self):
        self._put_code("new@example.com", "654321")
        st, body = self._post("/auth/login-email",
                              {"email": "new@example.com", "code": "654321"})
        self.assertEqual(st, 200)
        self.assertTrue(body.get("token"))
        row = self._user("new@example.com")
        self.assertIsNotNone(row)
        self.assertRegex(row[1], r"^\d{6}$")
        self.assertEqual(row[2], "用户" + row[1])
        # 同一邮箱再次验证码登录必须命中同一账号，而不是重复注册
        self._put_code("new@example.com", "111111")
        st2, body2 = self._post("/auth/login-email",
                                {"email": "new@example.com", "code": "111111"})
        self.assertEqual(st2, 200)
        self.assertEqual(body2.get("id"), row[0])

    def test_bad_code_invalidates_after_five_failures(self):
        self._put_code("bad@example.com", "222222")
        for _ in range(5):
            st, _ = self._post("/auth/login-email",
                               {"email": "bad@example.com", "code": "000000"})
            self.assertEqual(st, 400)
        # 达到失败上限后验证码被删除，正确验证码也不能再用
        st, _ = self._post("/auth/login-email",
                           {"email": "bad@example.com", "code": "222222"})
        # 连续失败达到阈值后账号进入 15 分钟锁定，即使验证码仍有效也拒绝。
        self.assertEqual(st, 429)

    def test_captcha_slider_and_single_use(self):
        cap = self._captcha()
        self.assertTrue(cap["captcha_id"])
        self.assertIn("captcha_x", cap)
        body = {"email": "x@example.com"}
        body.update(cap)
        st, _ = self._post("/auth/send-email-code", body)
        self.assertEqual(st, 503)  # 人机验证通过，才走到 SMTP 未配置
        st, resp = self._post("/auth/send-email-code", body)
        self.assertEqual(st, 400)
        self.assertIn("滑块验证", resp.get("error", ""))  # 同一挑战不可重放

    def test_legacy_image_captcha_still_works_for_old_app(self):
        cap = self._captcha_raw()
        self.assertIn("image", cap)  # 旧 App 继续拿图片
        self.assertNotIn("_debug_x", cap)
        self.assertNotIn("_debug_y", cap)
        body = {"email": "x@example.com", "captcha_id": cap["id"],
                "captcha_code": cap["debug_code"]}
        st, _ = self._post("/auth/send-email-code", body)
        self.assertEqual(st, 503)  # 图片校验通过，才走到 SMTP 未配置
        st2, resp = self._post("/auth/send-email-code", body)
        self.assertEqual(st2, 400)
        self.assertIn("已过期", resp.get("error", ""))  # 与滑块共用 id，一次即销毁

    def test_wrong_captcha_blocks_send(self):
        cap = self._captcha()
        st, resp = self._post("/auth/send-email-code", {
            "email": "x@example.com",
            "captcha_id": cap["captcha_id"],
            "captcha_x": cap["captcha_x"] + 80,
        })
        self.assertEqual(st, 400)
        self.assertIn("拼图位置", resp.get("error", ""))

    def test_send_code_without_captcha_is_400(self):
        st, body = self._post("/auth/send-email-code", {"email": "x@example.com"})
        self.assertEqual(st, 400)
        self.assertIn("安全验证", body.get("error", ""))

    def test_send_code_without_smtp_is_503(self):
        body = {"email": "x@example.com"}
        body.update(self._captcha())
        st, resp = self._post("/auth/send-email-code", body)
        self.assertEqual(st, 503)
        self.assertIn("邮箱服务", resp.get("error", ""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
