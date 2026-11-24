# -*- coding: utf-8 -*-
"""结构化日志与请求上下文。

日志是运维接口的一部分：统一字段名，后续接 journald / Loki / 任何采集器时不用改业务代码。
禁止记录 Authorization、请求体、密码、支付回调签名等敏感内容。
"""
from __future__ import annotations

import json
import logging
import sys
import time
import contextvars
from typing import Any

request_id_ctx: contextvars.ContextVar[str] = contextvars.ContextVar("community_request_id", default="-")

_RESERVED = {
    "name", "msg", "args", "levelname", "levelno", "pathname", "filename",
    "module", "exc_info", "exc_text", "stack_info", "lineno", "funcName",
    "created", "msecs", "relativeCreated", "thread", "threadName",
    "processName", "process", "taskName",
}


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "ts": round(time.time(), 3),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        for key, value in record.__dict__.items():
            if key in _RESERVED or key.startswith("_"):
                continue
            if value is None:
                continue
            payload[key] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


class TextFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        rid = getattr(record, "request_id", request_id_ctx.get())
        base = f"{self.formatTime(record, '%Y-%m-%d %H:%M:%S')} {record.levelname:<7} [{rid}] {record.name}: {record.getMessage()}"
        extras = []
        for key, value in record.__dict__.items():
            if key in _RESERVED or key.startswith("_") or key in ("request_id",):
                continue
            if value is not None:
                extras.append(f"{key}={value}")
        if extras:
            base += " " + " ".join(extras)
        if record.exc_info:
            base += "\n" + self.formatException(record.exc_info)
        return base


def configure_logging(level: str = "INFO", json_output: bool = True) -> None:
    logger = logging.getLogger("community")
    logger.setLevel(getattr(logging, level.upper(), logging.INFO))
    logger.propagate = False
    if logger.handlers:
        for h in list(logger.handlers):
            logger.removeHandler(h)
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter() if json_output else TextFormatter())
    logger.addHandler(handler)


def get_logger(name: str = "community") -> logging.Logger:
    if not name.startswith("community"):
        name = "community." + name
    return logging.getLogger(name)


def set_request_id(request_id: str) -> None:
    request_id_ctx.set(request_id or "-")


def get_request_id() -> str:
    return request_id_ctx.get()
