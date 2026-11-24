# -*- coding: utf-8 -*-
"""流萤社区 · 网络与认证安全基线。

集中放安全边界，避免各 handler 各自实现一套：
- CORS 白名单、统一安全响应头；
- 可信代理下的真实客户端 IP；
- 出站 URL 的 SSRF 校验；
- OTP / 登录限流用的服务端 HMAC 密钥。

本模块不记录密钥内容，只返回派生结果。
"""
from __future__ import annotations

import hashlib
import hmac
import ipaddress
import os
import socket
import time
import urllib.parse
from pathlib import Path
from typing import Iterable, Mapping


def normalize_origin(value: str) -> str:
    """只保留 scheme://host[:port]，拒绝路径、通配符和凭据。"""
    raw = (value or "").strip()
    if not raw:
        return ""
    try:
        p = urllib.parse.urlsplit(raw)
    except Exception:
        return ""
    if p.scheme not in ("http", "https") or not p.hostname:
        return ""
    if p.username or p.password:
        return ""
    host = p.hostname.lower()
    port = p.port
    default = 443 if p.scheme == "https" else 80
    netloc = host if port in (None, default) else "%s:%d" % (host, port)
    return "%s://%s" % (p.scheme, netloc)


def allowed_origins(values: Iterable[str]) -> tuple[str, ...]:
    return tuple(sorted({normalize_origin(v) for v in values if normalize_origin(v)}))


def cors_headers(origin: str, allowlist: tuple[str, ...]) -> dict:
    """有 Origin 且命中白名单才回 CORS；原生 App 无 Origin 时不加头。"""
    clean = normalize_origin(origin)
    if not clean or clean not in allowlist:
        return {}
    return {
        "Access-Control-Allow-Origin": clean,
        "Vary": "Origin",
        "Access-Control-Allow-Methods": "GET, HEAD, POST, PUT, DELETE, OPTIONS",
        "Access-Control-Allow-Headers":
            "Authorization, X-Community-Admin-Token, Content-Type, X-Request-Id, "
            "X-Client-Version, X-Client-Platform",
        "Access-Control-Max-Age": "86400",
    }


def security_headers(*, is_html: bool, secure: bool = True) -> dict:
    """API/HTML 通用的浏览器侧安全头。HTML 不套严格 CSP，避免打坏既有内联页。"""
    h = {
        "X-Content-Type-Options": "nosniff",
        "X-Frame-Options": "SAMEORIGIN",
        "Referrer-Policy": "strict-origin-when-cross-origin",
        "Permissions-Policy": "camera=(), microphone=(), geolocation=(), payment=()",
        "X-XSS-Protection": "0",
        "Cross-Origin-Opener-Policy": "same-origin",
    }
    if is_html:
        h["Content-Security-Policy"] = (
            "frame-ancestors 'self'; base-uri 'self'; object-src 'none'"
        )
    else:
        h["Content-Security-Policy"] = (
            "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; "
            "form-action 'none'"
        )
        h["Cross-Origin-Resource-Policy"] = "same-site"
    # 生产入口始终是 HTTPS（HTTP 响应里的 HSTS 会被浏览器忽略，不影响本地）。
    h["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    return h


def _parse_networks(values: Iterable[str]) -> tuple:
    nets = []
    for raw in values or ():
        if isinstance(raw, (ipaddress.IPv4Network, ipaddress.IPv6Network)):
            nets.append(raw)
            continue
        value = str(raw or "").strip()
        if not value:
            continue
        try:
            nets.append(ipaddress.ip_network(value, strict=False))
        except ValueError:
            continue
    return tuple(nets)


def _parse_ip(value: str):
    raw = (value or "").strip()
    if raw.startswith("[") and raw.endswith("]"):
        raw = raw[1:-1]
    try:
        return ipaddress.ip_address(raw)
    except ValueError:
        return None


def client_ip(headers: Mapping[str, str], peer: str, trusted_proxies: tuple) -> str:
    """只有直连 peer 属于可信代理时才相信 X-Real-IP / X-Forwarded-For。"""
    peer_ip = _parse_ip(peer)
    direct = str(peer_ip) if peer_ip else (peer or "")
    if peer_ip is None:
        return direct
    nets = _parse_networks(trusted_proxies or ())
    trusted = any(peer_ip in n for n in nets)
    if not trusted:
        return direct
    real = _parse_ip(headers.get("X-Real-IP", ""))
    if real is not None:
        return str(real)
    xff = headers.get("X-Forwarded-For", "")
    if xff:
        # 最左侧是原始客户端；最右侧只是最近一跳代理。代理可信时取最左侧。
        first = _parse_ip(xff.split(",", 1)[0])
        if first is not None:
            return str(first)
    return direct


def request_is_secure(headers: Mapping[str, str], peer: str, trusted_proxies: tuple) -> bool:
    """判断公网请求是否经 HTTPS 到达；仅可信代理可声明 X-Forwarded-Proto。"""
    peer_ip = _parse_ip(peer)
    nets = _parse_networks(trusted_proxies or ())
    trusted = bool(peer_ip is not None and any(peer_ip in n for n in nets))
    if trusted:
        proto = (headers.get("X-Forwarded-Proto", "").split(",", 1)[0].strip().lower())
        if proto:
            return proto == "https"
    return False


_PRIVATE_NETS = (
    ipaddress.ip_network("0.0.0.0/8"),
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("100.64.0.0/10"),
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("169.254.0.0/16"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.0.0.0/24"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("198.18.0.0/15"),
    ipaddress.ip_network("224.0.0.0/4"),
    ipaddress.ip_network("240.0.0.0/4"),
    ipaddress.ip_network("::1/128"),
    ipaddress.ip_network("fc00::/7"),
    ipaddress.ip_network("fe80::/10"),
    ipaddress.ip_network("ff00::/8"),
)

_BLOCKED_HOSTS = {
    "localhost", "localhost.localdomain", "metadata", "metadata.google.internal",
    "metadata.google.com", "instance-data", "169.254.169.254",
}


def _is_private_address(addr) -> bool:
    if addr.is_private or addr.is_loopback or addr.is_link_local or addr.is_multicast:
        return True
    if addr.is_unspecified or addr.is_reserved:
        return True
    return any(addr in n for n in _PRIVATE_NETS)


def validate_outbound_url(url: str, *, allow_private: bool = False) -> tuple[bool, str]:
    """校验服务端主动访问的 URL，阻断 SSRF、元数据地址与非标准端口。

    返回 (ok, reason)。official 调用方应把 allow_private 保持 False；
    本地开发如需访问 127.0.0.1，必须显式通过环境变量打开。
    """
    raw = (url or "").strip()
    if len(raw) > 2000:
        return False, "url_too_long"
    try:
        p = urllib.parse.urlsplit(raw)
    except Exception:
        return False, "invalid_url"
    if p.scheme not in ("http", "https"):
        return False, "scheme_not_allowed"
    if p.username or p.password:
        return False, "userinfo_not_allowed"
    host = (p.hostname or "").strip().lower().rstrip(".")
    if not host or host in _BLOCKED_HOSTS:
        return False, "host_blocked"
    if host.endswith(".local") or host.endswith(".internal") or host.endswith(".lan"):
        return False, "host_blocked"
    port = p.port
    if port is not None and port not in (80, 443):
        if not allow_private:
            return False, "port_not_allowed"
    # IP 字面量直接判定；域名解析后所有地址都必须是公网。
    literal = _parse_ip(host)
    addresses = []
    if literal is not None:
        addresses = [literal]
    else:
        try:
            infos = socket.getaddrinfo(host, port or (443 if p.scheme == "https" else 80),
                                       type=socket.SOCK_STREAM)
            addresses = [_parse_ip(info[4][0]) for info in infos]
            addresses = [a for a in addresses if a is not None]
        except Exception:
            return False, "dns_failed"
    if not addresses:
        return False, "dns_empty"
    if not allow_private and any(_is_private_address(a) for a in addresses):
        return False, "private_address"
    return True, ""


def security_secret() -> bytes:
    """获取本机安全密钥；首次创建 32 字节文件，权限 0600。

    环境变量 COMMUNITY_SECURITY_SECRET 优先，便于容器/CI 注入。
    """
    env = (os.environ.get("COMMUNITY_SECURITY_SECRET") or "").strip()
    if len(env) >= 32:
        return hashlib.sha256(env.encode("utf-8")).digest()
    path = Path(os.environ.get("COMMUNITY_SECURITY_SECRET_FILE")
                or "/www/wwwroot/yosar-data/config/security_secret")
    try:
        if path.exists():
            data = path.read_bytes().strip()
            if len(data) >= 32:
                return hashlib.sha256(data).digest()
        path.parent.mkdir(parents=True, exist_ok=True)
        data = os.urandom(32).hex().encode("ascii")
        fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)
        return hashlib.sha256(data).digest()
    except FileExistsError:
        try:
            data = path.read_bytes().strip()
            if len(data) >= 32:
                return hashlib.sha256(data).digest()
        except Exception:
            pass
    except Exception:
        pass
    # 最后兜底：不因为密钥文件写失败导致验证码流程整体崩掉；
    # 但进程重启会使未消费的 OTP 失效，属于可接受的 fail-closed 变体。
    return hashlib.sha256(("liuying-otp|" + os.environ.get("COMMUNITY_DB", "default")).encode()).digest()


def otp_hash(scope: str, value: str) -> str:
    """OTP 只存 HMAC，不把明文验证码写进数据库。"""
    key = security_secret()
    return hmac.new(key, ("%s|%s" % (scope, value)).encode("utf-8"), hashlib.sha256).hexdigest()


def constant_time_eq(left: str, right: str) -> bool:
    return hmac.compare_digest(str(left or ""), str(right or ""))


def client_ip_sort_key(ip: str) -> str:
    """用于日志/限流键，去掉 IPv6 方括号。"""
    return (ip or "").replace("[", "").replace("]", "")


def rate_limit_retry_after(window: int) -> str:
    return str(max(1, min(int(window or 60), 3600)))
