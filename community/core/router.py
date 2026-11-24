# -*- coding: utf-8 -*-
"""模块级路由注册表。

不是替代各 handler 内部的精确路由，而是给每条 API 路径一个明确的领域所有者：
- 只有前缀命中的模块才会被调用，避免每次请求把所有 handler 轮询一遍；
- 顺序即优先级，重叠前缀（/user、/video、/admin）由 routes.py 显式声明；
- handler 仍返回 True/False，未消费的路径继续交给后续匹配模块。
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable, Sequence


def path_matches(path: str, prefix: str) -> bool:
    if not prefix:
        return False
    p = prefix.rstrip("/")
    if not p:
        p = "/"
    return path == p or path.startswith(p + "/")


@dataclass(frozen=True)
class ModuleSpec:
    name: str
    module: Any
    prefixes: tuple[str, ...]
    description: str = ""

    def matches(self, path: str) -> bool:
        return any(path_matches(path, prefix) for prefix in self.prefixes)


class Router:
    def __init__(self, modules: Sequence[ModuleSpec]):
        self.modules = tuple(modules)

    def dispatch(self, handler: Any, c: Any, u: Any, api: str, method: str) -> str | None:
        for spec in self.modules:
            if not spec.matches(api):
                continue
            if spec.module.dispatch(handler, c, u, api, method):
                return spec.name
        return None

    def describe(self) -> list[dict[str, Any]]:
        return [
            {
                "name": spec.name,
                "prefixes": list(spec.prefixes),
                "description": spec.description,
            }
            for spec in self.modules
        ]

    def module_names(self) -> Iterable[str]:
        return (spec.name for spec in self.modules)
