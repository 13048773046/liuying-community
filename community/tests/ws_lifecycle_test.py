#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""WebSocket 生命周期回归：升级 101、hello 帧、客户端关闭后请求收尾。

历史上 `ws.py` 在升级后提前 `c.close()`，而 `request_connection` 退出时
仍会 commit + close，导致线上 `/community/api/ws` 偶发
`sqlite3.ProgrammingError: Cannot operate on a closed database` / 500。
本用例只起本地临时库和真实 socket，不连线上。
"""
import base64
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, BASE)
sys.path.insert(0, os.path.join(BASE, "tests"))

from message_e2e_fixture import build_db, TOK_ME  # noqa: E402


def _free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def main():
    db = os.path.join(tempfile.mkdtemp(prefix="ws-lifecycle-"), "db.sqlite")
    build_db(db)
    port = _free_port()
    env = dict(os.environ, COMMUNITY_DB=db, COMMUNITY_HOST="127.0.0.1",
               COMMUNITY_PORT=str(port), COMMUNITY_LOG_LEVEL="INFO")
    proc = subprocess.Popen(
        [sys.executable, os.path.join(BASE, "server.py")], cwd=BASE,
        env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        for _ in range(100):
            if proc.poll() is not None:
                raise RuntimeError(proc.stdout.read())
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    break
            except OSError:
                time.sleep(0.1)
        else:
            raise RuntimeError("server did not start")

        sock = socket.create_connection(("127.0.0.1", port), timeout=3)
        key = base64.b64encode(os.urandom(16)).decode()
        sock.sendall((
            f"GET /community/api/ws?token={TOK_ME} HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{port}\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        ).encode())
        head = sock.recv(4096)
        assert b"101 Switching Protocols" in head, head

        b1, b2 = sock.recv(2)
        length = b2 & 0x7F
        if length == 126:
            length = struct.unpack("!H", sock.recv(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", sock.recv(8))[0]
        payload = sock.recv(length) if length else b""
        assert b'"kind": "hello"' in payload, payload

        mask = os.urandom(4)
        body = b"\x03\xe8"
        masked = bytes(c ^ mask[i % 4] for i, c in enumerate(body))
        sock.sendall(b"\x88" + bytes([0x80 | len(body)]) + mask + masked)
        sock.close()
        time.sleep(1.2)
    finally:
        proc.terminate()
        try:
            log = proc.communicate(timeout=5)[0]
        except subprocess.TimeoutExpired:
            proc.kill()
            log = proc.communicate()[0]

    requests = [l for l in log.splitlines() if '"path":"/community/api/ws"' in l]
    assert requests, log[-1200:]
    assert any('"status":101' in l for l in requests), requests
    assert "Cannot operate on a closed database" not in log, log
    assert "unhandled_error" not in log, log
    print("WS lifecycle PASS: 101 / hello / close / request cleanup")


if __name__ == "__main__":
    main()
