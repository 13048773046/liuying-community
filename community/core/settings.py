# -*- coding: utf-8 -*-
"""社区服务配置：唯一的环境变量读取入口。

原则：
- 只在这里读 os.environ，其他模块拿不可变 Settings；
- 缺省值必须能本地启动；非法值在启动阶段直接失败，不把错误带到请求里；
- 不打印数据库路径、令牌、支付密钥等敏感配置。
"""
from __future__ import annotations

import os
import socket
from urllib.parse import urlsplit
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping

BASE_DIR = Path(__file__).resolve().parent.parent


def _env_int(env: Mapping[str, str], name: str, default: int, minimum: int, maximum: int) -> int:
    raw = (env.get(name) or "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} 必须是整数，当前为 {raw!r}") from exc
    if value < minimum or value > maximum:
        raise ValueError(f"{name} 必须在 {minimum}..{maximum} 之间，当前为 {value}")
    return value


def _env_bool(env: Mapping[str, str], name: str, default: bool) -> bool:
    raw = (env.get(name) or "").strip().lower()
    if not raw:
        return default
    if raw in ("1", "true", "yes", "on"):
        return True
    if raw in ("0", "false", "no", "off"):
        return False
    raise ValueError(f"{name} 必须是 true/false，当前为 {raw!r}")


def _env_text(env: Mapping[str, str], name: str, default: str) -> str:
    raw = (env.get(name) or "").strip()
    return raw or default


def _env_list(env: Mapping[str, str], name: str, default: str) -> tuple[str, ...]:
    raw = (env.get(name) or "").strip() or default
    return tuple(x.strip() for x in raw.split(",") if x.strip())


@dataclass(frozen=True)
class Settings:
    """一次进程生命周期内不变化的运行配置。"""

    service_name: str
    host: str
    port: int
    db_path: str
    files_dir: str
    templates_dir: str
    api_prefix: str
    public_base: str
    music_api_base: str
    music_public_base: str
    music_files_dir: str
    version: str
    instance_id: str
    log_level: str
    log_json: bool
    max_json_body: int
    max_upload_body: int
    request_id_header: str
    cors_origins: tuple[str, ...]
    trusted_proxies: tuple[str, ...]
    allow_private_outbound: bool

    @property
    def public_origin(self) -> str:
        """对外访问的协议+主机，不信任请求 Host/X-Forwarded-*。"""
        parsed = urlsplit(self.public_base)
        scheme = parsed.scheme if parsed.scheme in ("http", "https") else "https"
        host = parsed.hostname or "www.dbmt999.asia"
        port = ":%d" % parsed.port if parsed.port and parsed.port not in (80, 443) else ""
        return "%s://%s%s" % (scheme, host, port)

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "Settings":
        env = os.environ if env is None else env
        db_path = _env_text(env, "COMMUNITY_DB", "/www/wwwroot/yosar-data/db/tracks.db")
        host = _env_text(env, "COMMUNITY_HOST", "127.0.0.1")
        port = _env_int(env, "COMMUNITY_PORT", 8790, 1, 65535)
        api_prefix = _env_text(env, "COMMUNITY_API_PREFIX", "/community/api").rstrip("/")
        if not api_prefix.startswith("/"):
            raise ValueError("COMMUNITY_API_PREFIX 必须以 / 开头")
        level = _env_text(env, "COMMUNITY_LOG_LEVEL", "INFO").upper()
        if level not in ("DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"):
            raise ValueError(f"COMMUNITY_LOG_LEVEL 非法：{level}")
        return cls(
            service_name=_env_text(env, "COMMUNITY_SERVICE_NAME", "community"),
            host=host,
            port=port,
            db_path=db_path,
            files_dir=str(BASE_DIR / "files"),
            templates_dir=str(BASE_DIR / "templates"),
            api_prefix=api_prefix,
            public_base=_env_text(env, "COMMUNITY_PUBLIC_BASE", "https://www.yosar.cloud/community/api").rstrip("/"),
            music_api_base=_env_text(env, "COMMUNITY_MUSIC_API", "http://127.0.0.1:8788").rstrip("/"),
            music_public_base=_env_text(env, "COMMUNITY_MUSIC_PUBLIC_BASE",
                                        "https://www.yosar.cloud/music").rstrip("/"),
            music_files_dir=_env_text(env, "COMMUNITY_MUSIC_FILES", "/data-music/files").rstrip("/"),
            version=_env_text(env, "COMMUNITY_VERSION", "0.9.58"),
            instance_id=_env_text(env, "COMMUNITY_INSTANCE_ID", socket.gethostname()),
            log_level=level,
            log_json=_env_bool(env, "COMMUNITY_LOG_JSON", True),
            max_json_body=_env_int(env, "COMMUNITY_MAX_JSON_BODY", 1024 * 1024, 1024, 64 * 1024 * 1024),
            max_upload_body=_env_int(env, "COMMUNITY_MAX_UPLOAD_BODY", 64 * 1024 * 1024, 1024, 512 * 1024 * 1024),
            request_id_header=_env_text(env, "COMMUNITY_REQUEST_ID_HEADER", "X-Request-Id"),
            cors_origins=_env_list(
                env, "COMMUNITY_CORS_ORIGINS",
                "https://www.dbmt999.asia,https://dbmt999.asia,"
                "https://www.yosar.cloud,https://yosar.cloud"),
            trusted_proxies=_env_list(
                env, "COMMUNITY_TRUSTED_PROXIES",
                "127.0.0.1/32,::1/128"),
            allow_private_outbound=_env_bool(
                env, "COMMUNITY_ALLOW_PRIVATE_OUTBOUND", False),
        )

    @property
    def api_health(self) -> str:
        return self.api_prefix + "/health"

    @property
    def api_ready(self) -> str:
        return self.api_prefix + "/ready"

    @property
    def api_version(self) -> str:
        return self.api_prefix + "/version"


settings = Settings.from_env()
