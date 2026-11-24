# -*- coding: utf-8 -*-
"""热更新配置中心：平台/渠道/build/灰度/总开关的过滤规则。"""
import os
import sqlite3
import tempfile
import time
import unittest

from handlers import app_hot_update as hot


def _insert(c, key, platform="all", channel="stable", value="{}", status=1,
            priority=0, min_build=0, max_build=0, rollout=100,
            starts_at=0, ends_at=0, revision=1):
    cid = "t_" + key + "_" + platform + "_" + channel
    now = time.time()
    c.execute(
        "INSERT INTO community_app_hot_configs("
        "id,key,category,platform,channel,value_type,value_json,description,status,"
        "priority,min_build,max_build,rollout,starts_at,ends_at,revision,created,updated,published_at,created_by)"
        " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (cid, key, "config", platform, channel, "json", value, "", status, priority,
         min_build, max_build, rollout, starts_at, ends_at, revision, now, now, now, "test"),
    )
    return cid


class HotUpdateManifestTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.tmp.close()
        self.c = sqlite3.connect(self.tmp.name)
        self.c.row_factory = sqlite3.Row
        hot.init_schema(self.c)

    def tearDown(self):
        self.c.close()
        os.unlink(self.tmp.name)

    def manifest(self, platform="ios", channel="stable", build=118, device="device-a"):
        return hot._manifest(self.c, platform, channel, build, device, preview=False)

    def test_platform_scope_overrides_shared(self):
        _insert(self.c, "feature_flags", value='{"shorts": true, "apps": true}')
        _insert(self.c, "feature_flags", platform="android", value='{"shorts": false, "apps": true}')
        self.c.commit()
        ios = self.manifest("ios")
        android = self.manifest("android")
        self.assertEqual(ios["configs"]["feature_flags"]["shorts"], True)
        self.assertEqual(android["configs"]["feature_flags"]["shorts"], False)

    def test_build_range_and_channel(self):
        _insert(self.c, "copy.a", min_build=120, value='"only-new"')
        _insert(self.c, "copy.b", channel="beta", value='"beta-only"')
        self.c.commit()
        stable = self.manifest("ios", "stable", 118)
        self.assertNotIn("copy.a", stable["configs"])
        self.assertNotIn("copy.b", stable["configs"])
        beta = self.manifest("ios", "beta", 121)
        self.assertEqual(beta["configs"]["copy.a"], "only-new")
        self.assertEqual(beta["configs"]["copy.b"], "beta-only")

    def test_master_kill_switch(self):
        _insert(self.c, "maintenance", value='{"enabled": true}')
        hot._set_meta(self.c, "master", "0")
        self.c.commit()
        m = self.manifest()
        self.assertFalse(m["master"])
        self.assertEqual(m["configs"], {})
        hot._set_meta(self.c, "master", "1")
        self.c.commit()
        self.assertTrue(self.manifest()["configs"]["maintenance"]["enabled"])

    def test_rollout_is_stable_and_preview_ignores_it(self):
        _insert(self.c, "maintenance", value='{"enabled": true}', rollout=10)
        self.c.commit()
        hits = [d for d in ("a", "b", "c", "d", "e") if "maintenance" in self.manifest(device=d)["configs"]]
        # 10% 灰度：5 个设备不一定命中，但同一设备重复请求必须结果一致。
        first = self.manifest(device="stable-device")
        second = self.manifest(device="stable-device")
        self.assertEqual(first["configs"], second["configs"])
        preview = hot._manifest(self.c, "ios", "stable", 118, "stable-device", preview=True)
        self.assertIn("maintenance", preview["configs"])
        self.assertLessEqual(len(hits), 5)

    def test_time_window(self):
        _insert(self.c, "notice.a", starts_at=time.time() + 3600, value='"future"')
        self.c.commit()
        self.assertNotIn("notice.a", self.manifest()["configs"])


if __name__ == "__main__":
    unittest.main()
