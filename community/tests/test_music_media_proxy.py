# -*- coding: utf-8 -*-
"""音乐媒体代理验证：头像/背景/封面/配乐直接由社区从共享媒体目录提供。"""
import json
import os
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

PORT = 8801


def _build_db(path):
    c = sqlite3.connect(path, timeout=10)
    c.executescript("""
        CREATE TABLE users(id TEXT PRIMARY KEY, account TEXT, password_hash TEXT,
          name TEXT, avatar TEXT, created REAL, gender TEXT, age INTEGER,
          background_image TEXT, signature TEXT, ip_address TEXT, city TEXT,
          banned INTEGER DEFAULT 0, ban_reason TEXT, title TEXT, verified TEXT,
          verified_label TEXT, member TEXT, member_expire REAL, svip_expire REAL,
          email TEXT);
        CREATE TABLE tokens(token TEXT PRIMARY KEY, user_id TEXT, created REAL, expires REAL);
        CREATE TABLE follows(follower_id TEXT, following_id TEXT, created REAL);
        CREATE TABLE notifications(id TEXT PRIMARY KEY, user_id TEXT, type TEXT,
          title TEXT, content TEXT, from_user_id TEXT, from_user_name TEXT,
          track_id TEXT, track_title TEXT, is_read INTEGER, created REAL,
          comment_id TEXT, is_deleted INTEGER);
        CREATE TABLE tracks(id TEXT PRIMARY KEY, title TEXT, artist TEXT, album TEXT,
          cover TEXT, fname TEXT, size INTEGER, dur REAL, created REAL,
          play_count INTEGER, like_count INTEGER, share_count INTEGER,
          user_id TEXT, lrc TEXT, offline INTEGER DEFAULT 0);
        CREATE TABLE comments(id TEXT PRIMARY KEY, track_id TEXT);
    """)
    now = time.time()
    c.execute("INSERT INTO users(id,account,name,avatar,created,background_image) VALUES(?,?,?,?,?,?)",
              ("u1", "u1", "媒体用户", "u1_avatar.jpg", now, "u1_bg.jpg"))
    c.execute("INSERT INTO tracks(id,title,artist,album,cover,fname,size,dur,created,offline) "
              "VALUES(?,?,?,?,?,?,?,?,?,0)",
              ("tr1", "媒体测试歌", "测试歌手", "测试专辑", "tr1_cover.jpg",
               "tr1_song.m4a", 100, 10, now))
    c.commit()
    c.close()
    os.environ["COMMUNITY_DB"] = path
    import schema
    schema.DB_PATH = path
    schema.FILES_DIR = os.path.join(os.path.dirname(path), "community_files")
    schema.init_schema()


class MusicMediaProxyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="community_music_media_")
        media = os.path.join(cls.tmp, "music_files")
        os.makedirs(media)
        for name, data in (("u1_avatar.jpg", b"\xff\xd8\xff\xe0avatar"),
                           ("u1_bg.jpg", b"\xff\xd8\xff\xe0bg"),
                           ("tr1_cover.jpg", b"\xff\xd8\xff\xe0cover"),
                           ("tr1_song.m4a", b"\x00\x00\x00\x18ftypM4A " + b"x" * 80)):
            with open(os.path.join(media, name), "wb") as f:
                f.write(data)
        cls.db = os.path.join(cls.tmp, "media.db")
        _build_db(cls.db)
        env = dict(os.environ)
        env.update({
            "COMMUNITY_DB": cls.db,
            "COMMUNITY_PORT": str(PORT),
            "COMMUNITY_HOST": "127.0.0.1",
            "COMMUNITY_LOG_JSON": "false",
            "COMMUNITY_MUSIC_FILES": media,
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

    def _get(self, path, headers=None):
        req = urllib.request.Request("http://127.0.0.1:%d%s" % (PORT, path),
                                     headers=headers or {})
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, dict(r.headers), r.read()

    def test_avatar_and_background(self):
        st, _, body = self._get("/community/api/music/avatar/u1")
        self.assertEqual(st, 200)
        self.assertTrue(body.startswith(b"\xff\xd8"))
        st, _, body = self._get("/community/api/music/background/u1")
        self.assertEqual(st, 200)

    def test_cover(self):
        st, h, body = self._get("/community/api/music/cover/tr1")
        self.assertEqual(st, 200)
        self.assertTrue(h.get("Content-Type", "").startswith("image/jpeg"))
        self.assertTrue(body.startswith(b"\xff\xd8"))

    def test_audio_and_range(self):
        st, h, body = self._get("/community/api/music/files/tr1_song.m4a")
        self.assertEqual(st, 200)
        self.assertTrue(h.get("Content-Type", "").startswith("audio/"))
        st, h, part = self._get("/community/api/music/files/tr1_song.m4a",
                                {"Range": "bytes=0-15"})
        self.assertEqual(st, 206)
        self.assertEqual(len(part), 16)
        self.assertIn("bytes 0-15/", h.get("Content-Range", ""))

    def test_traversal_is_rejected(self):
        try:
            st, _, _ = self._get("/community/api/music/files/..%2Fsecret.txt")
        except urllib.error.HTTPError as e:
            st = e.code
        self.assertIn(st, (403, 404))


if __name__ == "__main__":
    unittest.main(verbosity=2)
