# -*- coding: utf-8 -*-
"""后端架构自检：配置、路由所有权、错误信封、健康端点。

运行：python3 -m unittest community/tests/test_architecture.py
"""
import json
import os
import sys
import tempfile
import time
import unittest
import urllib.request

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BASE not in sys.path:
    sys.path.insert(0, BASE)

from core.errors import ApiError, error_payload
from core.router import ModuleSpec, Router, path_matches
from core.settings import Settings
from routes import MODULES


class SettingsTest(unittest.TestCase):
    def test_defaults_and_prefix(self):
        s = Settings.from_env({})
        self.assertEqual(s.host, "127.0.0.1")
        self.assertEqual(s.port, 8790)
        self.assertEqual(s.api_prefix, "/community/api")
        self.assertEqual(s.api_health, "/community/api/health")

    def test_invalid_port_fails_fast(self):
        with self.assertRaises(ValueError):
            Settings.from_env({"COMMUNITY_PORT": "abc"})

    def test_bad_prefix_fails_fast(self):
        with self.assertRaises(ValueError):
            Settings.from_env({"COMMUNITY_API_PREFIX": "community/api"})


class RouterTest(unittest.TestCase):
    def test_path_matches_segments(self):
        self.assertTrue(path_matches("/post", "/post"))
        self.assertTrue(path_matches("/post/abc", "/post"))
        self.assertFalse(path_matches("/posts", "/post"))
        self.assertFalse(path_matches("/poster", "/post"))

    def test_first_matching_module_owns_route(self):
        calls = []

        class Mod:
            def __init__(self, name, handled):
                self.name = name
                self.handled = handled

            def dispatch(self, handler, c, u, api, method):
                calls.append((self.name, api, method))
                return self.handled

        router = Router((
            ModuleSpec("admin_apps", Mod("admin_apps", True), ("/admin/apps",)),
            ModuleSpec("admin_api", Mod("admin_api", True), ("/admin",)),
        ))
        owner = router.dispatch(object(), object(), object(), "/admin/apps/1", "GET")
        self.assertEqual(owner, "admin_apps")
        self.assertEqual(calls, [("admin_apps", "/admin/apps/1", "GET")])

    def test_unmatched_path_returns_none(self):
        router = Router((ModuleSpec("user", object(), ("/user",)),))
        self.assertIsNone(router.dispatch(object(), object(), object(), "/nope", "GET"))


class ManifestTest(unittest.TestCase):
    def test_manifest_names_unique_and_prefixes_present(self):
        names = [m.name for m in MODULES]
        self.assertEqual(len(names), len(set(names)))
        for m in MODULES:
            self.assertTrue(m.prefixes, m.name)
            self.assertTrue(m.description, m.name)

    def test_critical_overlaps_are_ordered(self):
        names = [m.name for m in MODULES]
        self.assertLess(names.index("admin_apps"), names.index("admin_api"))
        self.assertLess(names.index("content"), names.index("user"))
        self.assertLess(names.index("content"), names.index("upload"))

    def test_blocks_and_emoji_owned_by_user(self):
        for path in ("/blocks", "/block/u1", "/emojis", "/emoji/fav"):
            owners = [m.name for m in MODULES if m.matches(path)]
            self.assertIn("user", owners, path)


class ErrorTest(unittest.TestCase):
    def test_error_payload_keeps_legacy_fields(self):
        p = error_payload("bad", "code_x")
        self.assertEqual(p["ok"], False)
        self.assertEqual(p["error"], "bad")
        self.assertEqual(p["code"], "code_x")

    def test_api_error_is_exception(self):
        e = ApiError(404, "nope", "route_not_found")
        self.assertEqual(str(e), "nope")
        self.assertEqual(e.status, 404)


class HealthEndpointTest(unittest.TestCase):
    def test_health_ready_version_and_request_id(self):
        db_dir = tempfile.mkdtemp(prefix="community_arch_")
        db_path = os.path.join(db_dir, "arch.db")
        port = 8799
        env = dict(os.environ)
        env.update({"COMMUNITY_DB": db_path, "COMMUNITY_PORT": str(port),
                    "COMMUNITY_HOST": "127.0.0.1", "COMMUNITY_LOG_JSON": "false"})
        import subprocess
        proc = subprocess.Popen(
            [sys.executable, os.path.join(BASE, "server.py")],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for _ in range(40):
                try:
                    with urllib.request.urlopen(
                            "http://127.0.0.1:%d/health" % port, timeout=1) as r:
                        if r.status == 200:
                            break
                except Exception:
                    time.sleep(0.25)
            else:
                self.fail("server did not start")

            def get(path, headers=None):
                req = urllib.request.Request(
                    "http://127.0.0.1:%d%s" % (port, path), headers=headers or {})
                with urllib.request.urlopen(req, timeout=3) as r:
                    return r.status, dict(r.headers), json.loads(r.read().decode())

            st, h, body = get("/community/api/health", {"X-Request-Id": "arch-test"})
            self.assertEqual(st, 200)
            self.assertEqual(body["status"], "alive")
            self.assertEqual(h.get("X-Request-Id"), "arch-test")

            st, _, body = get("/community/api/ready")
            self.assertEqual(st, 200)
            self.assertTrue(body["ok"])

            st, _, body = get("/community/api/version")
            self.assertEqual(st, 200)
            self.assertTrue(body["version"])

        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except Exception:
                proc.kill()


if __name__ == "__main__":
    unittest.main(verbosity=2)
