# -*- coding: utf-8 -*-
"""主服务薄路由：应用市场 App API。"""
from app_market import api as APP_API


def dispatch(self, c, u, api, method):
    return APP_API.dispatch(self, c, u, api, method)
