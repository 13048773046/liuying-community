# -*- coding: utf-8 -*-
"""流萤社区 · 官方通知域（预留：定时推送/系统消息）。

客户端接口见 user.py（/official-messages）；管理接口见 admin_api.py。
"""
import re
import time

from common import db, resolve_token, official_msg


def dispatch(self, c, u, api, method):
    # 预留：后续可加定时广播、系统消息等
    return False
