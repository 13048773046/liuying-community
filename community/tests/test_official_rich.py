# -*- coding: utf-8 -*-
"""官方通知富文本规范化测试。

运行：python3 -m unittest community/tests/test_official_rich.py
"""
import os
import sys
import unittest

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BASE not in sys.path:
    sys.path.insert(0, BASE)

from rich_text import sanitize_official_rich


class OfficialRichSanitizeTest(unittest.TestCase):
    def test_styles_links_and_plain_text(self):
        doc = {
            "v": 1,
            "blocks": [
                {"type": "heading", "level": 2, "spans": [
                    {"text": "维护通知", "bold": True, "color": "accent"},
                ]},
                {"type": "paragraph", "spans": [
                    {"text": "今晚 "},
                    {"text": "23:00", "bold": True},
                    {"text": " 开始，详情见 "},
                    {"text": "公告", "url": "https://www.dbmt999.asia/notice"},
                ]},
                {"type": "bullet", "spans": [{"text": "提前保存草稿"}]},
                {"type": "quote", "spans": [
                    {"text": "预计 30 分钟", "italic": True, "color": "warning"},
                ]},
                {"type": "divider"},
            ],
        }
        rich, plain = sanitize_official_rich(doc)
        self.assertEqual(rich["v"], 1)
        self.assertEqual(rich["blocks"][0]["level"], 2)
        self.assertEqual(rich["blocks"][0]["spans"][0]["color"], "accent")
        self.assertEqual(rich["blocks"][1]["spans"][3]["url"],
                         "https://www.dbmt999.asia/notice")
        self.assertTrue(rich["blocks"][1]["spans"][3]["underline"])
        self.assertIn("• 提前保存草稿", plain)
        self.assertIn("维护通知", plain)

    def test_rejects_unsafe_url_and_unknown_style(self):
        doc = {"blocks": [
            {"type": "paragraph", "spans": [
                {"text": "bad", "url": "javascript:alert(1)"},
                {"text": "local", "url": "http://127.0.0.1/a"},
                {"text": "pwd", "url": "https://user:pass@example.com/x"},
                {"text": "evil", "color": "#ff00ff", "weird": True},
            ]},
            {"type": "script", "spans": [{"text": "x"}]},
        ]}
        rich, plain = sanitize_official_rich(doc)
        self.assertEqual(len(rich["blocks"]), 1)
        spans = rich["blocks"][0]["spans"]
        self.assertNotIn("url", spans[0])
        self.assertEqual(spans[1]["url"], "http://127.0.0.1/a")
        self.assertNotIn("url", spans[2])
        self.assertNotIn("color", spans[3])
        self.assertEqual(plain, "badlocalpwdevil")

    def test_soft_line_break_is_preserved(self):
        doc = {"blocks": [
            {"type": "paragraph", "spans": [
                {"text": "今晚 23:00 开始维护\n预计 30 分钟", "color": "accent"},
            ]},
        ]}
        rich, plain = sanitize_official_rich(doc)
        self.assertIn("\n", rich["blocks"][0]["spans"][0]["text"])
        self.assertIn("今晚 23:00 开始维护\n预计 30 分钟", plain)

    def test_image_only_message_is_valid(self):
        doc = {"blocks": [
            {"type": "image", "url": "https://cdn.example.com/a.png", "alt": "活动海报"},
        ]}
        rich, plain = sanitize_official_rich(doc)
        self.assertEqual(rich["blocks"][0]["type"], "image")
        self.assertEqual(plain, "活动海报")

    def test_empty_or_invalid(self):
        with self.assertRaises(ValueError):
            sanitize_official_rich({"blocks": []})
        with self.assertRaises(ValueError):
            sanitize_official_rich("not json")
        with self.assertRaises(ValueError):
            sanitize_official_rich({"blocks": [
                {"type": "paragraph", "spans": [{"text": "   "}]},
            ]})

    def test_block_limit(self):
        doc = {"blocks": [
            {"type": "paragraph", "spans": [{"text": "第%d行" % i}]}
            for i in range(40)
        ]}
        rich, _ = sanitize_official_rich(doc)
        self.assertEqual(len(rich["blocks"]), 24)


if __name__ == "__main__":
    unittest.main()
