# -*- coding: utf-8 -*-
"""统一错误类型与响应信封。

现有客户端依赖 `{ok: false, error: "..."}`；这里只增加可选 `code`，不改旧字段。
新代码用 ApiError 抛错，由 Application 统一转成 HTTP 响应；旧 handler 仍可继续 `_err`。
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass
class ApiError(Exception):
    status: int
    message: str
    code: str = ""

    def __post_init__(self) -> None:
        super().__init__(self.message)


def error_payload(message: str, code: str = "") -> dict[str, Any]:
    payload: dict[str, Any] = {"ok": False, "error": message}
    if code:
        payload["code"] = code
    return payload


def not_found(path: str) -> ApiError:
    return ApiError(404, f"接口不存在：{path}", "route_not_found")


def bad_request(message: str, code: str = "bad_request") -> ApiError:
    return ApiError(400, message, code)


def unauthorized(message: str = "未登录") -> ApiError:
    return ApiError(401, message, "unauthorized")


def forbidden(message: str = "无权访问") -> ApiError:
    return ApiError(403, message, "forbidden")


def conflict(message: str) -> ApiError:
    return ApiError(409, message, "conflict")


def too_many(message: str = "请求过于频繁，请稍后再试") -> ApiError:
    return ApiError(429, message, "rate_limited")


def unavailable(message: str = "服务暂不可用") -> ApiError:
    return ApiError(503, message, "service_unavailable")
