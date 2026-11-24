# -*- coding: utf-8 -*-
"""Spug 共享模板短信通道：配置解析、请求格式、失败透传。"""
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BASE not in sys.path:
    sys.path.insert(0, BASE)


class _MockSpug(BaseHTTPRequestHandler):
    received = []

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        data = json.loads(body)
        self.received.append((self.path, data))
        if data.get("to") == "13000000000":
            status, out = 200, {"code": 400, "msg": "余额不足"}
        elif data.get("to") == "13100000000":
            status, out = 403, {"msg": "IP 不在白名单"}
        else:
            status, out = 200, {"code": 200, "msg": "请求成功", "request_id": "test-req"}
        raw = json.dumps(out, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *args):
        pass


class SpugSmsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="community_spug_sms_")
        cfg = os.path.join(cls.tmp, "spug_sms.json")
        with open(cfg, "w", encoding="utf-8") as f:
            json.dump({"provider": "spug", "spug_template_code": "TESTCODE"}, f)
        os.environ["COMMUNITY_SMS_CONFIG"] = os.path.join(cls.tmp, "missing.json")
        os.environ["COMMUNITY_ALIYUN_SMS_CONFIG"] = os.path.join(cls.tmp, "missing-aliyun.json")
        os.environ["COMMUNITY_SPUG_SMS_CONFIG"] = cfg
        os.environ["COMMUNITY_SMS_PROVIDER"] = "spug"
        import importlib
        if "invite_core" in sys.modules:
            cls.core = importlib.reload(sys.modules["invite_core"])
        else:
            cls.core = importlib.import_module("invite_core")
        cls.srv = ThreadingHTTPServer(("127.0.0.1", 0), _MockSpug)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.core.SPUG_SMS_BASE = "http://127.0.0.1:%d/sms/" % cls.srv.server_address[1]
        cls.core.SPUG_SEND_BASE = "http://127.0.0.1:%d/send/" % cls.srv.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()

    def test_config(self):
        cfg = self.core.sms_config()
        self.assertEqual(cfg["provider"], "spug")
        self.assertEqual(cfg["spug_template_code"], "TESTCODE")

    def test_send_and_payload(self):
        _MockSpug.received.clear()
        self.assertEqual(self.core.send_sms_code("13800138000", "123456"), (True, ""))
        self.assertEqual(_MockSpug.received[-1],
                         ("/sms/TESTCODE", {"to": "13800138000", "code": "123456"}))

    def test_business_error(self):
        ok, err = self.core.send_sms_code("13000000000", "123456")
        self.assertFalse(ok)
        self.assertIn("余额不足", err)

    def test_http_error_body(self):
        ok, err = self.core.send_sms_code("13100000000", "123456")
        self.assertFalse(ok)
        self.assertIn("IP 不在白名单", err)

    def test_reject_non_official_url(self):
        cfg = {"provider": "spug", "spug_url": "http://127.0.0.1:1/evil"}
        self.assertEqual(self.core._spug_sms_url(cfg), "")

    def test_send_message_template_payload(self):
        cfg = {"provider": "spug", "spug_url": self.core.SPUG_SEND_BASE + "TESTCODE"}
        self.assertEqual(self.core._spug_sms_url(cfg), self.core.SPUG_SEND_BASE + "TESTCODE")
        self.assertEqual(
            self.core._spug_payload(cfg, cfg["spug_url"], "13800138000", "123456"),
            {"name": "流萤社区", "code": "123456", "number": "5", "targets": "13800138000"})

    def test_custom_message_payload(self):
        cfg = {"spug_payload": {"app": "{name}", "vcode": "{code}", "ttl": "{number}", "phone": "{phone}"}}
        self.assertEqual(
            self.core._spug_payload(cfg, self.core.SPUG_SEND_BASE + "TESTCODE",
                                    "13800138000", "123456"),
            {"app": "流萤社区", "vcode": "123456", "ttl": "5", "phone": "13800138000"})


if __name__ == "__main__":
    unittest.main()
