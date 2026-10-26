/// 通知实时总线（P0）：WebSocket 连接 + 未读数 + 通知事件流
///
/// 协议（community/handlers/ws.py）：
/// - 握手：wss://…/community/api/ws?token=<token>
/// - 下行 hello：{kind:'hello', uid, unread}
/// - 下行 notification：{kind:'notification', notification:{...}, unread}
/// - 服务端 25s ping，dart:io 自动回 pong
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

import '../config.dart';

class NotifyBus {
  NotifyBus._();
  static final NotifyBus shared = NotifyBus._();

  int _unread = 0;
  int _dmUnread = 0;
  bool _connected = false;
  IOWebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _retryTimer;
  String _token = '';
  bool _manualClose = false;

  /// 未读数变化通知（驱动导航栏红点）
  final ValueNotifier<int> unread = ValueNotifier<int>(0);

  /// 私信未读数（驱动消息页私信角标）
  final ValueNotifier<int> dmUnread = ValueNotifier<int>(0);

  /// 新通知事件（消息页可监听实时刷新）
  final StreamController<Map<String, dynamic>> onNotification =
      StreamController.broadcast();

  /// 新私信事件（{convId, from, content, created}，聊天页实时刷新）
  final StreamController<Map<String, dynamic>> onDm =
      StreamController.broadcast();

  int get currentUnread => _unread;

  int get currentDmUnread => _dmUnread;

  bool get connected => _connected;

  void connect(String token) {
    if (token.isEmpty) return;
    _token = token;
    _manualClose = false;
    _retryTimer?.cancel();
    _open();
  }

  void disconnect() {
    _manualClose = true;
    _retryTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _channel = null;
    _connected = false;
    _setUnread(0);
    _setDmUnread(0);
  }

  void _open() {
    if (_token.isEmpty || _manualClose) return;
    try {
      final uri = Uri.parse('$kApiBase/ws?token=$_token')
          .replace(scheme: kApiBase.startsWith('https') ? 'wss' : 'ws');
      _channel = IOWebSocketChannel.connect(uri);
      _sub = _channel!.stream.listen(
        _onData,
        onDone: _onClosed,
        onError: (_) => _onClosed(),
      );
      _connected = true;
    } catch (_) {
      _scheduleRetry();
    }
  }

  void _onData(dynamic raw) {
    try {
      final j = jsonDecode(raw as String) as Map<String, dynamic>;
      final kind = (j['kind'] ?? '') as String;
      if (kind == 'hello' || kind == 'notification') {
        _setUnread(((j['unread'] ?? 0) as num).toInt());
      }
      if (kind == 'dm') {
        _setDmUnread(((j['unread'] ?? 0) as num).toInt());
        if (j['dm'] != null) {
          onDm.add(Map<String, dynamic>.from(j['dm'] as Map));
        }
      }
      if (kind == 'notification' && j['notification'] != null) {
        onNotification.add(Map<String, dynamic>.from(j['notification'] as Map));
      }
    } catch (_) {}
  }

  void _onClosed() {
    _connected = false;
    _channel = null;
    if (!_manualClose) _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_manualClose || _token.isEmpty) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 8), _open);
  }

  void _setDmUnread(int n) {
    if (_dmUnread == n) return;
    _dmUnread = n;
    dmUnread.value = n;
  }

  void _setUnread(int n) {
    if (_unread == n) return;
    _unread = n;
    unread.value = n;
  }
}
