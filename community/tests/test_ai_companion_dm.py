# -*- coding: utf-8 -*-
"""流小萤私信陪伴模式回归。

运行：python3 -m unittest community/tests/test_ai_companion_dm.py -v
"""
import os
import sys
import unittest
from unittest import mock

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, BASE)

import ai_bot_dm as DM


class CompanionDmTest(unittest.TestCase):
    STICKERS = [
        {"code": "lyemoji22", "name": "比心", "image": "emoji_official/liuying/ly22.webp"},
        {"code": "lyemoji26", "name": "抱抱", "image": "emoji_official/liuying/ly26.webp"},
    ]

    def _decide(self, state=None, history=None, reply="嗯，我在听。今天是不是有点累？",
                stickers=None, latest="今天加班到很晚"):
        state = state if state is not None else {"mode": "companion"}
        history = history if history is not None else [
            {"role": "user", "content": "今天加班到很晚"},
            {"role": "assistant", "content": "辛苦了，先坐下歇一会儿。"},
        ]
        saved = {}

        def save(peer, value, last_msg_id=""):
            saved.update(value)

        with mock.patch.object(DM, "_peer_name", return_value="阿岚"), \
                mock.patch.object(DM.CORE, "dm_history", return_value=history), \
                mock.patch.object(DM.CORE, "conv_state", return_value=state), \
                mock.patch.object(DM.CORE, "conv_state_set", side_effect=save), \
                mock.patch.object(DM, "_sticker_catalog", return_value=stickers or []), \
                mock.patch.object(DM.MEDIA, "llm_text", return_value=reply) as llm:
            out = DM.decide("peer_1", latest)
            prompt = llm.call_args.args[0]
        return out, prompt, saved

    def test_prompt_is_companion_not_assistant(self):
        out, prompt, _ = self._decide()
        self.assertEqual(out["intent"], "none")
        self.assertIn("陪伴型聊天对象", prompt)
        self.assertIn("不是工作助理", prompt)
        self.assertIn("不提供发帖、点赞、评论、收藏、改资料", prompt)
        self.assertIn("此刻是否安全", prompt)
        self.assertIn("不要主动说“今晚/这么晚/这个点", prompt)
        self.assertNotIn('"intent"', prompt)
        self.assertNotIn("json", prompt.lower())

    def test_old_pending_action_is_cleared_and_never_executed(self):
        out, _, saved = self._decide(
            state={"pending": {"intent": "post.like", "args": {"target": "p1"}}})
        self.assertEqual(out["intent"], "none")
        self.assertIsNone(saved.get("pending"))
        self.assertEqual(saved.get("mode"), "companion")
        self.assertFalse(hasattr(DM, "_execute"))
        self.assertFalse(hasattr(DM, "INTENTS"))

    def test_empty_model_output_gets_companion_fallback(self):
        out, _, _ = self._decide(reply="")
        self.assertIn("我在", out["reply"])
        self.assertNotIn("发帖", out["reply"])
        self.assertNotIn("点赞", out["reply"])

    def test_reply_cleanup_strips_prefix_and_caps_length(self):
        text = "流小萤：" + "今天先别想那么多。" * 80
        clean = DM._clean_reply(text)
        self.assertFalse(clean.startswith("流小萤"))
        self.assertLessEqual(len(clean), DM.MAX_REPLY_CHARS + 1)
        self.assertTrue(clean.endswith("。") or clean.endswith("…"))

    def test_liuying_sticker_is_selectable_and_parsed(self):
        out, prompt, saved = self._decide(
            stickers=self.STICKERS,
            latest="今天有点难过，想抱抱",
            reply="过来，抱一下。\n表情：lyemoji26")
        self.assertEqual(out["sticker"]["code"], "lyemoji26")
        self.assertEqual(out["sticker"]["image"], "emoji_official/liuying/ly26.webp")
        self.assertIn("lyemoji26=抱抱", prompt)
        self.assertIn("输出格式固定为两行", prompt)
        self.assertEqual(saved.get("last_stickers"), ["lyemoji26"])

    def test_catalog_reads_id_and_name_columns(self):
        import sqlite3
        conn = sqlite3.connect(":memory:")
        conn.execute("CREATE TABLE community_emojis (id TEXT, code TEXT, image TEXT,"
                     " category TEXT, sort INTEGER, active INTEGER)")
        conn.execute("INSERT INTO community_emojis VALUES"
                     " ('lyemoji26','抱抱','emoji_official/liuying/ly26.webp','流萤表情',1,1)")
        conn.commit()
        with mock.patch.object(DM.CORE, "db", return_value=conn):
            catalog = DM._sticker_catalog()
        self.assertEqual(catalog[0]["code"], "lyemoji26")
        self.assertEqual(catalog[0]["name"], "抱抱")

    def test_sticker_not_sent_in_crisis_or_opt_out(self):
        crisis, _, _ = self._decide(
            stickers=self.STICKERS,
            latest="最近有点撑不下去了",
            reply="我在，先告诉我你现在安全吗？\n表情：lyemoji26")
        self.assertIsNone(crisis["sticker"])
        opt_out, _, _ = self._decide(
            stickers=self.STICKERS,
            latest="别发表情包了",
            reply="好，不发了。\n表情：lyemoji26")
        self.assertIsNone(opt_out["sticker"])

    def test_sticker_not_repeated_and_numeric_code_normalized(self):
        repeated, _, _ = self._decide(
            state={"mode": "companion", "last_stickers": ["lyemoji26"]},
            stickers=self.STICKERS,
            latest="再抱一下",
            reply="抱抱。\n表情：26")
        self.assertIsNone(repeated["sticker"])
        fresh, _, _ = self._decide(
            stickers=self.STICKERS,
            latest="今天好开心",
            reply="真好呀。\n表情：22")
        self.assertEqual(fresh["sticker"]["code"], "lyemoji22")

    def test_sticker_send_uses_image_message(self):
        with mock.patch.object(DM.CORE, "send_dm", return_value=True) as send:
            ok = DM._send_sticker("peer_1", self.STICKERS[1])
        self.assertTrue(ok)
        send.assert_called_once_with(
            "peer_1", "emoji_official/liuying/ly26.webp", msg_type="image")

    def test_rates_are_chat_friendly(self):
        from ai_bot_schema import DEFAULT_POLICY
        self.assertGreaterEqual(DEFAULT_POLICY["max_dm_actions_per_user_day"], 40)
        self.assertGreaterEqual(DEFAULT_POLICY["max_dm_replies_per_minute"], 30)


if __name__ == "__main__":
    unittest.main(verbosity=2)
