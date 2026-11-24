/// 全站关注关系总线：一次拉取 / 一次操作，所有页面共享同一份状态。
///
/// 背景：短视频、用户主页、帖子详情、关注列表各自维护 `_following`，
/// 用户在 A 页关注后回到 B 页仍显示「关注」，甚至点一下会误取关。
/// 这里把「uid → 是否已关注」收敛为单例，页面只订阅不重复拉取。
library;

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../models/feed_item.dart' show boolOf;

class FollowBus {
  FollowBus._();

  /// 已知关系集合；key 不存在 = 未知（需要按需 sync）。
  static final ValueNotifier<Map<String, bool>> relations =
      ValueNotifier<Map<String, bool>>(const {});

  /// 防止同一 uid 并发重复拉 profile。
  static final Map<String, Future<bool?>> _inflight = {};

  /// 防止同一 uid 在详情页/主页/列表同时点关注导致请求乱序。
  static final Map<String, Future<bool>> _toggleInflight = {};

  static bool? relationOf(String uid) => relations.value[uid];

  static void setRelation(String uid, bool following) {
    if (uid.isEmpty) return;
    if (relations.value[uid] == following) return;
    relations.value = {...relations.value, uid: following};
  }

  static void clear() {
    _inflight.clear();
    _toggleInflight.clear();
    relations.value = const {};
  }

  /// 从用户主页接口同步一次关注关系。返回 null 表示拉取失败/未登录。
  static Future<bool?> sync(String uid, {bool force = false}) async {
    if (uid.isEmpty || uid == ApiClient.userId) {
      setRelation(uid, false);
      return false;
    }
    if (!force) {
      final known = relationOf(uid);
      if (known != null) return known;
      final running = _inflight[uid];
      if (running != null) return running;
    }
    final future = _fetch(uid);
    _inflight[uid] = future;
    try {
      return await future;
    } finally {
      if (identical(_inflight[uid], future)) _inflight.remove(uid);
    }
  }

  static Future<bool?> _fetch(String uid) async {
    try {
      final j = await ApiClient.userProfile(uid);
      final user = j['user'];
      // 兼容两种返回：标准主页接口在 user.following，轻量接口直接给 following。
      if (user is Map) {
        final following = boolOf(user['following']);
        setRelation(uid, following);
        return following;
      }
      if (j.containsKey('following')) {
        final following = boolOf(j['following']);
        setRelation(uid, following);
        return following;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 切换关注；调用前会确保关系已知，避免「本来已关注却误触取关」。
  static Future<bool> toggle(String uid) {
    final running = _toggleInflight[uid];
    if (running != null) return running;
    final future = _toggle(uid);
    _toggleInflight[uid] = future;
    return future.whenComplete(() {
      if (identical(_toggleInflight[uid], future)) {
        _toggleInflight.remove(uid);
      }
    });
  }

  static Future<bool> _toggle(String uid) async {
    var current = relationOf(uid);
    if (current == null) current = await sync(uid) ?? false;
    final j = await ApiClient.toggleFollow(uid);
    final next = boolOf(j['following'], !current);
    setRelation(uid, next);
    return next;
  }

  /// 显式设置目标状态（false=取关）。已经是目标状态时不发请求。
  static Future<bool> setFollowing(String uid, bool following) async {
    var current = relationOf(uid);
    if (current == null) current = await sync(uid) ?? false;
    if (current == following) return current;
    return toggle(uid);
  }
}
