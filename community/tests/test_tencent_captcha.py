# -*- coding: utf-8 -*-
"""腾讯滑动验证码服务端票据校验的单元测试。"""
import json
import os
import sqlite3
import sys
import unittest
from unittest import mock

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BASE not in sys.path:
    sys.path.insert(0, BASE)

import tencent_captcha


class _Resp:
    def __init__(self, payload):
        self._payload = payload

    def read(self, _n=65536):
        return self._payload

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class TencentCaptchaTest(unittest.TestCase):
    def setUp(self):
        self._env = mock.patch.dict(os.environ, {
            "COMMUNITY_TENCENT_CAPTCHA_APPID": "199999164",
            "COMMUNITY_TENCENT_CAPTCHA_SECRET": "E4kwK9AcXQMHkktRItyMEyQnp",
            "COMMUNITY_TENCENT_SECRET_ID": "AKIDTEST",
            "COMMUNITY_TENCENT_SECRET_KEY": "SECRETTEST",
            "COMMUNITY_TENCENT_CAPTCHA_MODE": "1",
        }, clear=False)
        self._env.start()
        self.c = sqlite3.connect(":memory:")
        tencent_captcha._ensure(self.c)

    def tearDown(self):
        self._env.stop()
        self.c.close()

    def _mock_response(self, payload):
        return mock.patch.object(
            tencent_captcha.urllib.request, "urlopen",
            return_value=_Resp(json.dumps(payload).encode()))

    def test_status_falls_back_without_keys(self):
        with mock.patch.dict(os.environ, {
            "COMMUNITY_TENCENT_CAPTCHA_APPID": "",
            "COMMUNITY_TENCENT_CAPTCHA_SECRET": "",
        }, clear=False):
            self.assertEqual(tencent_captcha.status(),
                             {"provider": "cap", "app_id": "", "mode": "1"})
            self.assertFalse(tencent_captcha.enabled())

    def test_verify_ok_then_replay_rejected(self):
        with self._mock_response({"response": "1", "err_code": "0"}):
            ok, msg = tencent_captcha.verify(
                self.c, "ticket-abc", "rand-xyz", "1.2.3.4")
            self.assertTrue(ok, msg)
        with self._mock_response({"response": "1", "err_code": "0"}):
            ok2, msg2 = tencent_captcha.verify(
                self.c, "ticket-abc", "rand-xyz", "1.2.3.4")
        self.assertFalse(ok2)
        self.assertIn("已使用", msg2)

    def test_verify_rejected(self):
        with self._mock_response({"response": "0", "err_code": "7"}):
            ok, msg = tencent_captcha.verify(
                self.c, "ticket-bad", "rand", "1.2.3.4")
        self.assertFalse(ok)
        self.assertIn("不匹配", msg)

    def test_missing_ticket(self):
        ok, msg = tencent_captcha.verify(self.c, "", "", "1.2.3.4")
        self.assertFalse(ok)
        self.assertIn("滑块", msg)

    def test_network_error_fails_closed(self):
        with mock.patch.object(
                tencent_captcha.urllib.request, "urlopen",
                side_effect=OSError("boom")):
            ok, msg = tencent_captcha.verify(
                self.c, "ticket-net", "rand", "1.2.3.4")
        self.assertFalse(ok)
        self.assertIn("连接失败", msg)

    def test_page_html_never_leaks_secret(self):
        html = tencent_captcha.page_html()
        self.assertIn("199999164", html)
        self.assertNotIn("E4kwK9AcXQMHkktRItyMEyQnp", html)
        self.assertIn("TencentCaptchaBridge", html)


if __name__ == "__main__":
    unittest.main()
