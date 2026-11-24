/// 双端热更新：拉取远程配置、落地缓存、驱动维护模式 / 公告 / 功能开关。
///
/// 边界：这是配置与运营策略的热更新，不替换已签名安装包内的 Dart 代码。
/// 真正的代码变更仍需要重新构建 APK / IPA；后台改配置不需要。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../config.dart';

/// 一份已经通过服务端平台/渠道/build/灰度过滤后的配置快照。
@immutable
class HotConfig {
  const HotConfig({
    this.revision = 0,
    this.master = true,
    this.configs = const <String, dynamic>{},
    this.platform = '',
    this.channel = 'stable',
    this.fetchedAt,
  });

  static const HotConfig empty = HotConfig();

  final int revision;
  final bool master;
  final Map<String, dynamic> configs;
  final String platform;
  final String channel;
  final DateTime? fetchedAt;

  factory HotConfig.fromMap(Map<String, dynamic> map) {
    final raw = map['configs'];
    return HotConfig(
      revision: _int(map['revision']),
      master: map['master'] != false,
      configs: raw is Map
          ? raw.map((k, v) => MapEntry(k.toString(), v))
          : const <String, dynamic>{},
      platform: (map['platform'] ?? '').toString(),
      channel: (map['channel'] ?? 'stable').toString(),
      fetchedAt: DateTime.now(),
    );
  }

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}') ?? 0;
  }

  Map<String, dynamic>? objectOf(String key) {
    final v = configs[key];
    return v is Map ? v.map((k, x) => MapEntry(k.toString(), x)) : null;
  }

  bool get maintenanceEnabled {
    if (!master) return false;
    final m = objectOf('maintenance');
    return m != null && m['enabled'] == true;
  }

  String get maintenanceTitle {
    final m = objectOf('maintenance');
    final s = (m?['title'] ?? '').toString().trim();
    return s.isEmpty ? '流萤社区维护中' : s;
  }

  String get maintenanceMessage {
    final m = objectOf('maintenance');
    final s = (m?['message'] ?? '').toString().trim();
    return s.isEmpty ? '我们正在升级服务，请稍后再回来。' : s;
  }

  String get maintenanceEta {
    final m = objectOf('maintenance');
    return (m?['eta'] ?? '').toString().trim();
  }

  /// 首页公告；维护模式下不展示，避免两套遮罩打架。
  Map<String, dynamic>? get announcement {
    if (!master || maintenanceEnabled) return null;
    final a = objectOf('home_announcement');
    if (a == null || a['enabled'] != true) return null;
    final title = (a['title'] ?? '').toString().trim();
    final body = (a['body'] ?? '').toString().trim();
    if (title.isEmpty && body.isEmpty) return null;
    return a;
  }

  String get announcementId {
    final a = announcement;
    final id = (a?['id'] ?? '').toString().trim();
    if (id.isNotEmpty) return id;
    // 后台没给 id 时，用内容做稳定 fingerprint，避免每次刷新都重新出现。
    // 不能用 String.hashCode：Dart 的字符串哈希不保证跨进程稳定。
    final seed = '${a?['title']}|${a?['body']}|${a?['actionUrl']}';
    var h = 0x811c9dc5;
    for (final c in seed.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return 'auto-${h.toRadixString(16)}';
  }

  /// 未配置时默认开启，避免升级后旧配置把功能误关。
  bool featureEnabled(String key, {bool fallback = true}) {
    if (!master) return fallback;
    final flags = objectOf('feature_flags');
    final v = flags?[key];
    return v is bool ? v : fallback;
  }

  /// 流萤表情的“文字混排”开关。
  ///
  /// 新版本默认关闭：表情走独立图片消息，不再往输入框塞 `[表情名]`。
  /// 但渲染层继续兼容历史正文里的 token，所以老帖、老私信不会变成字面代码。
  bool get inlineTextEmojiEnabled =>
      featureEnabled('inline_text_emoji', fallback: false);

  /// 任意自定义远程配置；客户端未识别的 key 会安全忽略。
  Object? remote(String key, {Object? fallback}) => configs[key] ?? fallback;
}

class HotUpdateService {
  HotUpdateService._();

  static final HotUpdateService instance = HotUpdateService._();

  /// UI 只监听这一个入口；配置变化时整棵相关子树重建，不轮询。
  final ValueNotifier<HotConfig> config = ValueNotifier<HotConfig>(HotConfig.empty);

  static const _kSnapshot = 'community_hot_update_snapshot_v1';
  static const _kDevice = 'community_hot_update_device_v1';
  static const _kDismissed = 'community_hot_update_dismissed_v1';
  static const _minInterval = Duration(minutes: 5);
  static const _maintenanceInterval = Duration(seconds: 30);

  SharedPreferences? _prefs;
  String _deviceId = '';
  DateTime? _lastAttempt;
  bool _started = false;
  bool _refreshing = false;
  Timer? _maintenanceTimer;

  String get deviceId => _deviceId;
  String get channel =>
      const String.fromEnvironment('HOT_CHANNEL', defaultValue: 'stable');

  /// 启动时先读本地快照，再静默拉一次；网络失败不影响启动。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      _prefs = await SharedPreferences.getInstance();
      _deviceId = await _loadOrCreateDeviceId();
      final cached = _prefs?.getString(_kSnapshot);
      if (cached != null && cached.isNotEmpty) {
        final map = jsonDecode(cached);
        if (map is Map<String, dynamic>) {
          config.value = HotConfig.fromMap(map);
        } else if (map is Map) {
          config.value = HotConfig.fromMap(map.cast<String, dynamic>());
        }
      }
    } catch (_) {}
    unawaited(refresh(force: true));
  }

  Future<String> _loadOrCreateDeviceId() async {
    final prefs = _prefs;
    final old = prefs?.getString(_kDevice) ?? '';
    if (old.isNotEmpty) return old;
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    final id = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await prefs?.setString(_kDevice, id);
    return id;
  }

  /// [force] 为 false 时 5 分钟内只发一次请求，回前台/切页不会打爆后端。
  Future<void> refresh({bool force = false}) async {
    if (_refreshing) return;
    final now = DateTime.now();
    final last = _lastAttempt;
    if (!force && last != null && now.difference(last) < _minInterval) return;
    _refreshing = true;
    _lastAttempt = now;
    try {
      final res = await ApiClient.hotUpdate(
        platform: Platform.isIOS ? 'ios' : 'android',
        version: kAppVersion,
        build: kAppBuild,
        channel: channel,
        device: _deviceId,
      );
      final next = HotConfig.fromMap(res);
      if (next.master || next.configs.isEmpty || next.revision >= config.value.revision) {
        config.value = next;
        await _prefs?.setString(_kSnapshot, jsonEncode(res));
      }
    } catch (_) {
      // 静默失败：保留上次可用快照，不让一次断网把维护模式/公告全清空。
    } finally {
      _refreshing = false;
      _scheduleMaintenanceRetry();
    }
  }

  void _scheduleMaintenanceRetry() {
    _maintenanceTimer?.cancel();
    if (!config.value.maintenanceEnabled) return;
    // 维护期间每 30 秒重试，后台一关掉维护用户就能自动回来，不用杀进程。
    _maintenanceTimer = Timer(_maintenanceInterval, () {
      unawaited(refresh(force: true));
    });
  }

  Future<bool> isAnnouncementDismissed(String id) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    return (prefs.getString(_kDismissed) ?? '') == id;
  }

  Future<void> dismissAnnouncement(String id) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.setString(_kDismissed, id);
  }

  /// 测试与登出清理用：只清远端快照，不换设备 id。
  Future<void> clearCache() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.remove(_kSnapshot);
    config.value = HotConfig.empty;
  }
}
