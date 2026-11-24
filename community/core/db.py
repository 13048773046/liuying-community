# -*- coding: utf-8 -*-
"""请求级数据库连接与事务边界。

- 连接仍由 common.db() 创建，保证 schema 初始化、busy_timeout、row_factory 只有一份实现；
- 每个请求一个连接，请求结束 commit/rollback 并 close，避免 handler 漏 close 泄漏；
- 旧 handler 内部显式 commit 仍然有效（重复 commit 无副作用），但异常路径由这里统一回滚。
"""
from __future__ import annotations

import sqlite3
from contextlib import contextmanager
from typing import Iterator


def connect() -> sqlite3.Connection:
    from common import db
    return db()


@contextmanager
def request_connection() -> Iterator[sqlite3.Connection]:
    c = connect()
    try:
        yield c
        c.commit()
    except Exception:
        try:
            c.rollback()
        except Exception:
            pass
        raise
    finally:
        try:
            c.close()
        except Exception:
            pass


def check_ready() -> bool:
    """readiness：能连库并执行最小查询，且社区表已初始化。"""
    c = connect()
    try:
        one = c.execute("SELECT 1").fetchone()
        if not one or one[0] != 1:
            return False
        row = c.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='community_posts'"
        ).fetchone()
        return bool(row)
    finally:
        c.close()
