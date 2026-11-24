/// 通知实时总线（P0）：WebSocket 连接 + 未读数 + 通知事件流
///
/// 协议（community/handlers/ws.py）：
/// - 握手：`wss://…/community/api/ws?token=<token>`
/// - 下行 hello：{kind:'hello', uid, unread}
/// - 下行 notification：{kind:'notification', notification:{...}, unread}
/// - 服务端 25s ping，dart:io 自动回 pong
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

import '../api/client.dart';

int _intOf(dynamic v) =>
    v is num ? v.toInt() : (int.tryParse('${v ?? 0}') ?? 0);

class NotifyBus {
  NotifyBus._();
  static final NotifyBus shared = NotifyBus._();

  /// 视觉回归/单测可关闭 WebSocket，避免测试环境代理导致的连接异常。
  static bool enabled = true;

  int _unread = 0;
  int _dmUnread = 0;
  int _officialUnread = 0;
  bool _connected = false;
  IOWebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _retryTimer;
  String _token = '';
  bool _manualClose = false;

  /// 连接代次：旧连接的 onDone/onError 可能在新连接建立后才回调，
  /// 用代次把它们丢弃，避免旧回调把新连接标记为断开并触发重复重连。
  int _generation = 0;

  /// 未读数变化通知（驱动导航栏红点）
  final ValueNotifier<int> unread = ValueNotifier<int>(0);

  /// 私信未读数（驱动消息页私信角标）
  final ValueNotifier<int> dmUnread = ValueNotifier<int>(0);

  /// 官方通知未读数（消息页系统通知入口 / 底部总红点）
  final ValueNotifier<int> officialUnread = ValueNotifier<int>(0);

  /// 互动未读 + 私信未读 + 官方未读的合计（驱动底部导航「消息」总红点）
  final ValueNotifier<int> totalUnread = ValueNotifier<int>(0);

  /// 新通知事件（消息页可监听实时刷新）
  final StreamController<Map<String, dynamic>> onNotification =
      StreamController.broadcast();

  /// 新私信事件（{id, convId, from, content, preview, created, convUnread}）
  final StreamController<Map<String, dynamic>> onDm =
      StreamController.broadcast();

  /// 新官方通知事件（{id, content, rich, contentType, createdAt...}）
  final StreamController<Map<String, dynamic>> onOfficial =
      StreamController.broadcast();

  /// 对方已读回执事件（{convId, peer, readAt}，聊天页把己方气泡更新为已读）
  final StreamController<Map<String, dynamic>> onDmRead =
      StreamController.broadcast();

  int get currentUnread => _unread;

  int get currentDmUnread => _dmUnread;

  int get currentOfficialUnread => _officialUnread;

  int get currentTotalUnread => _unread + _dmUnread + _officialUnread;

  bool get connected => _connected;

  /// 本地清零未读（用于「全部已读」后立刻消红点）
  void clearUnread() => _setUnread(0);

  /// 本地清零私信未读
  void clearDmUnread() => _setDmUnread(0);

  /// 本地清零官方未读
  void clearOfficialUnread() => _setOfficialUnread(0);

  /// 本地设置未读（用于按接口返回值同步）
  void setUnread(int n) => _setUnread(n);

  /// 本地设置私信未读（用于按接口返回值同步）
  void setDmUnread(int n) => _setDmUnread(n);

  /// 本地设置官方未读（用于按接口返回值同步）
  void setOfficialUnread(int n) => _setOfficialUnread(n);

  void connect(String token) {
    if (!enabled || token.isEmpty) return;
    _token = token;
    _manualClose = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _generation++;
    final generation = _generation;
    // 同一个账号从首页/登录页/我的页都会调用 connect；先关旧连接，
    // 否则会留下多条 WebSocket，同一条私信被处理多次、红点也会跳。
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    _connected = false;
    _open(generation);
  }

  void disconnect() {
    _manualClose = true;
    _generation++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    _connected = false;
    _setUnread(0);
    _setDmUnread(0);
    _setOfficialUnread(0);
  }

  void _open(int generation) {
    if (generation != _generation || _token.isEmpty || _manualClose) return;
    try {
      final base = ApiClient.baseUrl;
      final wsBase = base.startsWith('https://')
          ? 'wss://${base.substring(8)}'
          : base.replaceFirst('http://', 'ws://');
      final uri = Uri.parse('$wsBase/ws');
      // token 放 Authorization 头，不进 URL/代理日志/Referer。
      final channel = IOWebSocketChannel.connect(
        uri,
        headers: {'Authorization': 'Bearer $_token'},
        connectTimeout: const Duration(seconds: 8),
      );
      _channel = channel;
      _sub = channel.stream.listen(
        (raw) => _onData(raw, generation),
        onDone: () => _onClosed(generation),
        onError: (_) => _onClosed(generation),
      );
      _connected = true;
    } catch (_) {
      _scheduleRetry(generation);
    }
  }

  void _onData(dynamic raw, int generation) {
    if (generation != _generation) return;
    try {
      final text = raw is String ? raw : utf8.decode(raw as List<int>);
      final j = jsonDecode(text) as Map<String, dynamic>;
      final kind = (j['kind'] ?? '').toString();
      if (kind == 'hello' || kind == 'notification') {
        _setUnread(_intOf(j['unread']));
        if (kind == 'hello') {
          if (j['dmUnread'] != null) {
            _setDmUnread(_intOf(j['dmUnread']));
          }
          if (j['officialUnread'] != null) {
            _setOfficialUnread(_intOf(j['officialUnread']));
          }
        }
      }
      if (kind == 'dm_read') {
        onDmRead.add(Map<String, dynamic>.from(j));
      }
      if (kind == 'dm') {
        _setDmUnread(_intOf(j['unread']));
        final dm = j['dm'];
        if (dm is Map) {
          onDm.add(Map<String, dynamic>.from(dm));
        }
      }
      if (kind == 'official') {
        if (j['officialUnread'] != null) {
          _setOfficialUnread(_intOf(j['officialUnread']));
        } else {
          // 广播通知没有逐用户未读数：本地 +1，下一次 hello/REST 校准。
          _setOfficialUnread(_officialUnread + 1);
        }
        final message = j['message'];
        if (message is Map) {
          onOfficial.add(Map<String, dynamic>.from(message));
        }
      }
      final notification = j['notification'];
      if (kind == 'notification' && notification is Map) {
        onNotification.add(Map<String, dynamic>.from(notification));
      }
    } catch (_) {}
  }

  void _onClosed(int generation) {
    if (generation != _generation) return;
    _connected = false;
    _channel = null;
    if (!_manualClose) _scheduleRetry(generation);
  }

  void _scheduleRetry(int generation) {
    if (generation != _generation || _manualClose || _token.isEmpty) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 8), () => _open(generation));
  }

  void _setDmUnread(int n) {
    final v = n < 0 ? 0 : n;
    if (_dmUnread == v) return;
    _dmUnread = v;
    dmUnread.value = v;
    _syncTotal();
  }

  void _setOfficialUnread(int n) {
    final v = n < 0 ? 0 : n;
    if (_officialUnread == v) return;
    _officialUnread = v;
    officialUnread.value = v;
    _syncTotal();
  }

  void _setUnread(int n) {
    final v = n < 0 ? 0 : n;
    if (_unread == v) return;
    _unread = v;
    unread.value = v;
    _syncTotal();
  }

  void _syncTotal() {
    final total = _unread + _dmUnread + _officialUnread;
    if (totalUnread.value != total) totalUnread.value = total;
  }
}
