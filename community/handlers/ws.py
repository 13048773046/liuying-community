# -*- coding: utf-8 -*-
"""流萤社区 · WebSocket 实时通知（基础实现：握手/文本帧/心跳/推送）。

协议：
- GET /community/api/ws?token=<token>（或 Authorization Bearer）升级握手。
- 服务端下行：{"kind":"notification","notification":{...},"unread":N}
- 心跳：服务端 25s ping；客户端 pong；断线清理。
"""
import base64
import hashlib
import json
import os
import struct
import threading
import time
import socket

from common import resolve_token, db

_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
# uid -> set(conn)
_CLIENTS = {}
_CLIENTS_LOCK = threading.Lock()
_PING_INTERVAL = 25.0


class WSConn:
    def __init__(self, sock, uid, handler):
        self.sock = sock
        self.uid = uid
        self.handler = handler
        self.last_pong = time.time()
        self.alive = True
        self.lock = threading.Lock()
        with _CLIENTS_LOCK:
            _CLIENTS.setdefault(uid, set()).add(self)

    def send_text(self, text):
        try:
            with self.lock:
                payload = text.encode("utf-8")
                mask = b"\x81"
                ln = len(payload)
                if ln < 126:
                    frame = bytes([0x81, ln]) + payload
                elif ln < 65536:
                    frame = bytes([0x81, 126]) + struct.pack(">H", ln) + payload
                else:
                    frame = bytes([0x81, 127]) + struct.pack(">Q", ln) + payload
                self.sock.sendall(frame)
        except Exception:
            self.close()

    def send_ping(self):
        try:
            with self.lock:
                self.sock.sendall(b"\x89\x00")
        except Exception:
            self.close()

    def close(self):
        if not self.alive:
            return
        self.alive = False
        with _CLIENTS_LOCK:
            s = _CLIENTS.get(self.uid, set())
            s.discard(self)
            if not s:
                _CLIENTS.pop(self.uid, None)
        try:
            self.sock.close()
        except Exception:
            pass

    def read_loop(self):
        """读取客户端帧（pong/文本/关闭），阻塞运行。"""
        try:
            while self.alive:
                hdr = self._recv_exact(2)
                if not hdr:
                    break
                b0, b1 = hdr[0], hdr[1]
                opcode = b0 & 0x0F
                masked = b1 & 0x80
                ln = b1 & 0x7F
                if ln == 126:
                    ln = struct.unpack(">H", self._recv_exact(2))[0]
                elif ln == 127:
                    ln = struct.unpack(">Q", self._recv_exact(8))[0]
                if masked:
                    mask_key = self._recv_exact(4)
                else:
                    mask_key = b""
                payload = b""
                if ln > 0:
                    payload = self._recv_exact(ln)
                    if mask_key:
                        payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))
                if opcode == 0x8:      # close
                    self.close()
                    break
                elif opcode == 0x9:    # ping
                    self.send_text_pong()
                elif opcode == 0xA:    # pong
                    self.last_pong = time.time()
                elif opcode == 0x1:    # text
                    try:
                        data = json.loads(payload.decode("utf-8"))
                        self._on_message(data)
                    except Exception:
                        pass
        except Exception:
            pass
        finally:
            self.close()

    def send_text_pong(self):
        try:
            with self.lock:
                self.sock.sendall(b"\x8a\x00")
        except Exception:
            pass

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                return None
            buf += chunk
        return buf

    def _on_message(self, data):
        # 预留：行为上报等
        pass


def ws_push(uid, data):
    """向用户推送 JSON（无连接时静默）。"""
    if not uid:
        return
    with _CLIENTS_LOCK:
        conns = list(_CLIENTS.get(uid, set()))
    if not conns:
        return
    text = json.dumps(data, ensure_ascii=False)
    for conn in conns:
        conn.send_text(text)


def _do_handshake(handler, sock, token):
    key = handler.headers.get("Sec-WebSocket-Key", "")
    if not key:
        return False
    accept = base64.b64encode(hashlib.sha1(
        (key + _WS_GUID).encode()).digest()).decode()
    handler.send_response(101)
    handler.send_header("Upgrade", "websocket")
    handler.send_header("Connection", "Upgrade")
    handler.send_header("Sec-WebSocket-Accept", accept)
    handler.end_headers()
    return True


def dispatch(self, c, u, api, method):
    if api != "/ws":
        return False
    if method != "GET":
        self._err(405, "method not allowed")
        return True
    token = (u.query and urllib_parse_query(u.query).get("token") or "")
    auth = self.headers.get("Authorization", "")
    if not token:
        scheme, _, tok = auth.partition(" ")
        if scheme.lower() == "bearer":
            token = tok
    uid = resolve_token(c, token) if token else None
    if not uid:
        self._err(401, "unauthorized")
        return True
    try:
        # 取底层 socket（ThreadingHTTPServer）
        sock = self.connection
        if not _do_handshake(self, sock, token):
            self._err(400, "bad handshake")
            return True
        conn = WSConn(sock, uid, self)
        # 初始推送未读数
        try:
            n = c.execute("SELECT COUNT(*) FROM notifications WHERE user_id=? AND is_read=0"
                          " AND type!='official' AND is_deleted=0", (uid,)).fetchone()[0]
            conn.send_text(json.dumps({"kind": "hello", "uid": uid, "unread": n},
                                      ensure_ascii=False))
        except Exception:
            pass
        c.close()
        # 读循环 + 心跳（主线程）
        threading.Thread(target=conn.read_loop, daemon=True).start()
        last_ping = time.time()
        while conn.alive:
            time.sleep(1)
            if time.time() - last_ping > _PING_INTERVAL:
                conn.send_ping()
                last_ping = time.time()
    except Exception:
        pass
    # 连接关闭后不再响应（连接已被接管）
    return True


def urllib_parse_query(qs):
    import urllib.parse
    return urllib.parse.parse_qs(qs)
