# -*- coding: utf-8 -*-
"""交付兜底：从 find 输出里挑成品的纯函数测试。"""
import importlib.util
import os
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("af_handler", ROOT / "handlers" / "af.py")


def _load_paths():
    # handlers/af.py 依赖 common/af_core，直接 import 需要服务端环境；
    # 这里只抽取纯函数源码，避免测试拉起数据库与 HTTP 栈。
    src = (ROOT / "handlers" / "af.py").read_text(encoding="utf-8")
    start = src.index("DELIVERY_EXT = ")
    end = src.index("def _tree(", start)
    ns = {"__name__": "af_delivery_test"}
    exec(src[start:end], ns)
    return ns["delivery_paths"]


delivery_paths = _load_paths()


class DeliveryPathsTest(unittest.TestCase):
    def test_picks_newest_three_and_filters(self):
        out = "\n".join([
            "1795000000.0|/work/report.pdf",
            "1794999999.0|/work/.hidden.html",
            "1794999998.0|/work/tmp_notes.txt",
            "1794999997.0|/work/dir/",
            "1794999996.0|/notwork/home.html",
            "1794999995.0|/work/page.html",
            "1794999994.0|/work/table.xlsx",
            "1794999993.0|/work/old.zip",
        ])
        self.assertEqual(delivery_paths(out, 3), [
            "/work/report.pdf", "/work/page.html", "/work/table.xlsx"])

    def test_duplicate_and_garbage(self):
        out = "bad\n1|/work/a.html\n2|/work/a.html\n3|/work/b.md\n"
        self.assertEqual(delivery_paths(out, 5), ["/work/a.html", "/work/b.md"])

    def test_empty(self):
        self.assertEqual(delivery_paths(""), [])
        self.assertEqual(delivery_paths(None), [])


if __name__ == "__main__":
    unittest.main()
