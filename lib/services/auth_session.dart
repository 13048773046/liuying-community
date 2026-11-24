import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../config.dart';
import '../models/feed_item.dart' show boolOf, verifiedOf;
import 'notify_bus.dart';
import 'secure_store.dart';

/// 本地保存的历史账号（与音乐端 AuthManager.savedAccounts 同构）
class SavedAccount {
  final String uid;
  final String name;
  final String account;
  final String avatar;
  final String token;
  final bool verified;
  final String verifiedLabel;
  final bool isAi;

  const SavedAccount({
    required this.uid,
    required this.name,
    required this.account,
    required this.avatar,
    required this.token,
    this.verified = false,
    this.verifiedLabel = '',
    this.isAi = false,
  });

  Map<String, dynamic> toJson() => {
    'uid': uid,
    'name': name,
    'account': account,
    'avatar': avatar,
    'token': token,
    'verified': verified,
    'verifiedLabel': verifiedLabel,
    'isAi': isAi,
  };

  factory SavedAccount.fromJson(Map<String, dynamic> j) {
    final label = (j['verifiedLabel'] ?? '').toString().trim();
    return SavedAccount(
      uid: (j['uid'] ?? '').toString(),
      name: (j['name'] ?? '').toString(),
      account: (j['account'] ?? '').toString(),
      avatar: (j['avatar'] ?? '').toString(),
      token: (j['token'] ?? '').toString(),
      verified: verifiedOf(j['verified']) || label.isNotEmpty,
      verifiedLabel: label,
      isAi: boolOf(j['isAi']) || label.toUpperCase() == 'AI',
    );
  }

  /// 头像地址（音乐 /api/avatar/{uid}）
  String get avatarUrl => avatarUrlOf(uid);
}

/// 账号会话管理：多账号保存 / 切换 / 退出（与音乐端行为一致）
class AuthSession {
  static const _keyAccounts = 'community_saved_accounts';

  /// 账号会话版本：登录 / 切换 / 退出后自增，页面据此重新拉取自己的资料。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static void _bump() => revision.value++;

  /// 读取历史账号列表（当前登录账号也在其中）
  static Future<List<SavedAccount>> loadAccounts() async {
    final raw = await SecureStore.read(_keyAccounts);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => SavedAccount.fromJson(e as Map<String, dynamic>))
          .toList();
      return list;
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveAccounts(List<SavedAccount> list) async {
    try {
      await SecureStore.write(
        _keyAccounts,
        jsonEncode(list.map((e) => e.toJson()).toList()),
      );
    } catch (_) {
      // token 已安全写入；历史账号列表写失败不应阻断本次登录。
    }
  }

  /// 登录成功后保存账号（去重，排到最前）
  static Future<void> saveAccount(
    Map<String, dynamic> user,
    String token,
  ) async {
    final uid = (user['id'] ?? '').toString();
    if (uid.isEmpty) return;
    final label = (user['verifiedLabel'] ?? '').toString().trim();
    final acc = SavedAccount(
      uid: uid,
      name: (user['name'] ?? '').toString(),
      account: (user['account'] ?? '').toString(),
      avatar: (user['avatar'] ?? '').toString(),
      token: token,
      verified: verifiedOf(user['verified']) || label.isNotEmpty,
      verifiedLabel: label,
      isAi: boolOf(user['isAi']) || label.toUpperCase() == 'AI',
    );
    final list = await loadAccounts();
    final next = [acc, ...list.where((e) => e.uid != uid)].take(10).toList();
    await _saveAccounts(next);
    _bump();
  }

  /// 资料变化后静默更新本地历史账号里的昵称/头像，不触发会话重建。
  static Future<void> updateSavedProfile(Map<String, dynamic> user) async {
    final uid = (user['id'] ?? '').toString();
    if (uid.isEmpty) return;
    final list = await loadAccounts();
    if (list.isEmpty) return;
    var changed = false;
    final next = list.map((e) {
      if (e.uid != uid) return e;
      final name = (user['name'] ?? e.name).toString();
      final avatar = (user['avatar'] ?? e.avatar).toString();
      final label = (user['verifiedLabel'] ?? e.verifiedLabel)
          .toString()
          .trim();
      final verified = verifiedOf(user['verified']) || label.isNotEmpty;
      final isAi = boolOf(user['isAi']) || label.toUpperCase() == 'AI';
      if (name == e.name &&
          avatar == e.avatar &&
          verified == e.verified &&
          label == e.verifiedLabel &&
          isAi == e.isAi) {
        return e;
      }
      changed = true;
      return SavedAccount(
        uid: e.uid,
        name: name,
        account: e.account,
        avatar: avatar,
        token: e.token,
        verified: verified,
        verifiedLabel: label,
        isAi: isAi,
      );
    }).toList();
    if (changed) await _saveAccounts(next);
  }

  /// 切换到历史账号：注入 token + 重连实时通知
  static Future<void> switchTo(SavedAccount acc) async {
    ApiClient.token = acc.token;
    ApiClient.userId = acc.uid;
    ApiClient.meProfile = {
      'id': acc.uid,
      'name': acc.name,
      'avatar': acc.avatar,
      'verified': acc.verified,
      'verifiedLabel': acc.verifiedLabel,
      'isAi': acc.isAi,
    };
    ApiClient.meSignature = null;
    NotifyBus.shared.disconnect();
    NotifyBus.shared.connect(acc.token);
    await SecureStore.write(SecureStore.tokenKey, acc.token);
    _bump();
  }

  /// 退出登录：服务端撤销 token + 清本地安全存储 + 断开通知（保留历史账号列表）
  static Future<void> logout() async {
    await ApiClient.logout();
    ApiClient.token = null;
    ApiClient.userId = null;
    ApiClient.meProfile = null;
    ApiClient.meSignature = null;
    NotifyBus.shared.disconnect();
    await SecureStore.delete(SecureStore.tokenKey);
    _bump();
  }
}
