# -*- coding: utf-8 -*-
"""人机验证入口：Cap（默认）、腾讯（有密钥时）、旧滑块/图片兼容。"""
import os

from common import rate_limit, client_ip
import captcha
import tencent_captcha


def _cap_page_html() -> bytes:
    path = os.path.abspath(os.path.join(
        os.path.dirname(__file__), "..", "templates", "invite", "cap", "app.html"))
    with open(path, "rb") as f:
        return f.read()


def dispatch(self, c, u, api, method):
    if api == "/captcha/config" and method == "GET":
        # 只下发公开配置，绝不下发任何服务端密钥。
        self._send(200, {"ok": True, **tencent_captcha.status()})
        return True

    if api == "/captcha/page" and method == "GET":
        self._send(200, tencent_captcha.page_html(),
                   "text/html; charset=utf-8")
        return True

    if api == "/captcha/cap-page" and method == "GET":
        try:
            self._send(200, _cap_page_html(), "text/html; charset=utf-8")
        except OSError:
            self._err(503, "安全验证页面加载失败")
        return True

    if api == "/captcha/cap/challenge" and method == "POST":
        if not rate_limit(self, "captcha_cap_challenge"):
            self._err(429, "安全验证请求过于频繁，请稍后再试")
            return True
        data = captcha.cap_challenge()
        if not data:
            self._err(503, "安全验证服务暂不可用，请稍后重试")
            return True
        self._send(200, data)
        return True

    if api == "/captcha/cap/redeem" and method == "POST":
        if not rate_limit(self, "captcha_cap_redeem"):
            self._err(429, "安全验证请求过于频繁，请稍后再试")
            return True
        body = self._json_body(max_len=256 * 1024)
        if not isinstance(body, dict):
            self._err(400, "安全验证请求异常")
            return True
        self._send(200, captcha.cap_redeem(body))
        return True

    if api != "/captcha" or method != "GET":
        return False
    if not rate_limit(self, "captcha"):
        self._err(429, "获取人机验证过于频繁，请稍后再试")
        return True
    try:
        data = captcha.issue(c, client_ip(self))
    except Exception:
        self._err(503, "安全验证生成失败，请稍后再试")
        return True
    self._send(200, {"ok": True, **data})
    return True
