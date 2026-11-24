# -*- coding: utf-8 -*-
"""后台用户资料编辑回归。

运行：python3 -m unittest community/tests/test_admin_user_edit.py -v
"""
import os
import sqlite3
import sys
import unittest

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, BASE)

from handlers import admin_api
from handlers.auth import _verify_password


DDL = """
CREATE TABLE users(
  id TEXT PRIMARY KEY, account TEXT, password_hash TEXT, name TEXT, avatar TEXT,
  created REAL, gender TEXT DEFAULT '', age INTEGER DEFAULT 0,
  background_image TEXT DEFAULT '', signature TEXT DEFAULT '', banned INTEGER DEFAULT 0,
  ban_reason TEXT DEFAULT '', title TEXT DEFAULT '', verified TEXT DEFAULT '',
  verified_label TEXT DEFAULT '', city TEXT DEFAULT '', email TEXT DEFAULT '',
  email_verified INTEGER DEFAULT 0, is_ai INTEGER DEFAULT 0
);
CREATE TABLE community_exp(user_id TEXT PRIMARY KEY, exp INTEGER, level INTEGER);
CREATE TABLE community_members(user_id TEXT PRIMARY KEY, level TEXT, expire REAL);
CREATE TABLE community_admins(token TEXT, user_id TEXT, level INTEGER, name TEXT, role TEXT,
  perms TEXT, created REAL);
CREATE TABLE community_phone_accounts(
  phone_hash TEXT PRIMARY KEY, phone_mask TEXT DEFAULT '', user_id TEXT UNIQUE,
  created REAL, verified_at REAL
);
CREATE TABLE community_invite_profiles(
  user_id TEXT PRIMARY KEY, code TEXT, phone_hash TEXT DEFAULT '',
  phone_mask TEXT DEFAULT '', phone_verified_at REAL DEFAULT 0,
  created REAL, updated REAL
);
CREATE TABLE community_invite_bindings(
  id TEXT PRIMARY KEY, invitee_id TEXT, phone_hash TEXT DEFAULT '', phone_mask TEXT DEFAULT ''
);
"""


class AdminUserEditTest(unittest.TestCase):
    def setUp(self):
        self.c = sqlite3.connect(":memory:")
        for sql in DDL.split(";"):
            if sql.strip():
                self.c.execute(sql)
        self.c.execute(
            "INSERT INTO users(id,account,password_hash,name,created,title,email) VALUES(?,?,?,?,?,?,?)",
            ("u1", "acct1", "oldhash", "阿岚", 1, "创作者", "a@example.com"))
        self.c.execute(
            "INSERT INTO users(id,account,password_hash,name,created,title,email) VALUES(?,?,?,?,?,?,?)",
            ("u2", "acct2", "oldhash", "小北", 2, "", "b@example.com"))
        self.c.execute("INSERT INTO community_admins(token,user_id,level,name,role,perms,created)"
                       " VALUES('t','admin1',1,'超级管理员','super','',1)")
        self.c.commit()

    def test_payload_contains_display_fields(self):
        u = admin_api._admin_user_payload(self.c, "u1")
        self.assertEqual(u["account"], "acct1")
        self.assertEqual(u["title"], "创作者")
        self.assertEqual(u["email"], "a@example.com")
        self.assertEqual(u["phoneMask"], "")
        self.assertEqual(u["background"], "")
        self.assertEqual(u["adminName"], "")

    def test_update_profile_fields(self):
        changed, u = admin_api._admin_update_user(self.c, "u1", {
            "name": "新昵称", "gender": "女", "age": 26, "city": "苏州",
            "signature": "今天也要开心", "avatar": "u1_avatar.png",
            "background": "u1_background.jpg",
        })
        self.assertEqual(u["name"], "新昵称")
        self.assertEqual(u["gender"], "女")
        self.assertEqual(u["age"], 26)
        self.assertEqual(u["city"], "苏州")
        self.assertEqual(u["signature"], "今天也要开心")
        self.assertEqual(u["avatar"], "u1_avatar.png")
        self.assertEqual(u["background"], "u1_background.jpg")
        self.assertIn("背景图", changed)
        self.assertEqual(u["account"], "acct1")
        self.assertEqual(u["title"], "创作者")

    def test_email_uniqueness_and_clear(self):
        _, u = admin_api._admin_update_user(self.c, "u1", {"email": "new@example.com"})
        self.assertEqual(u["email"], "new@example.com")
        with self.assertRaises(ValueError):
            admin_api._admin_update_user(self.c, "u2", {"email": "new@example.com"})
        _, u = admin_api._admin_update_user(self.c, "u1", {"email": ""})
        self.assertEqual(u["email"], "")

    def test_password_requires_super(self):
        with self.assertRaises(PermissionError):
            admin_api._admin_update_user(self.c, "u1", {"password": "newpass123"},
                                         allow_password=False)
        _, u = admin_api._admin_update_user(self.c, "u1", {"password": "newpass123"},
                                            allow_password=True)
        row = self.c.execute("SELECT password_hash FROM users WHERE id='u1'").fetchone()
        self.assertTrue(_verify_password("newpass123", row[0]))
        self.assertFalse(_verify_password("oldhash", row[0]))

    def test_phone_bind_mask_and_clear(self):
        _, u = admin_api._admin_update_user(self.c, "u1", {"phone": "13900000001"})
        self.assertEqual(u["phoneMask"], "139****0001")
        acct = self.c.execute("SELECT phone_mask,user_id FROM community_phone_accounts"
                              " WHERE phone_hash<>''").fetchone()
        self.assertEqual(acct[0], "139****0001")
        self.assertEqual(acct[1], "u1")
        with self.assertRaises(ValueError):
            admin_api._admin_update_user(self.c, "u2", {"phone": "13900000001"})
        _, u = admin_api._admin_update_user(self.c, "u1", {"phone": ""})
        self.assertEqual(u["phoneMask"], "")
        self.assertFalse(self.c.execute(
            "SELECT 1 FROM community_phone_accounts WHERE user_id='u1'").fetchone())

    def test_age_and_name_validation(self):
        with self.assertRaises(ValueError):
            admin_api._admin_update_user(self.c, "u1", {"age": 151})
        with self.assertRaises(ValueError):
            admin_api._admin_update_user(self.c, "u1", {"name": "  "})
        with self.assertRaises(ValueError):
            admin_api._admin_update_user(self.c, "u1", {"phone": "12345"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
