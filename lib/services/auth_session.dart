import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../config.dart';
import 'notify_bus.dart';

/// 本地保存的历史账号（与音乐端 AuthManager.savedAccounts 同构）
class SavedAccount {
  final String uid;
  final String name;
  final String account;
  final String avatar;
  final String token;

  const SavedAccount({
    required this.uid,
    required this.name,
    required this.account,
    required this.avatar,
    required this.token,
  });

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'name': name,
        'account': account,
        'avatar': avatar,
        'token': token,
      };

  factory SavedAccount.fromJson(Map<String, dynamic> j) => SavedAccount(
        uid: (j['uid'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        account: (j['account'] ?? '') as String,
        avatar: (j['avatar'] ?? '') as String,
        token: (j['token'] ?? '') as String,
      );

  /// 头像地址（音乐 /api/avatar/{uid}）
  String get avatarUrl => avatarUrlOf(uid);
}

/// 账号会话管理：多账号保存 / 切换 / 退出（与音乐端行为一致）
class AuthSession {
  static const _keyAccounts = 'community_saved_accounts';

  /// 读取历史账号列表（当前登录账号也在其中）
  static Future<List<SavedAccount>> loadAccounts() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_keyAccounts);
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
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
        _keyAccounts, jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  /// 登录成功后保存账号（去重，排到最前）
  static Future<void> saveAccount(
      Map<String, dynamic> user, String token) async {
    final uid = (user['id'] ?? '') as String;
    if (uid.isEmpty) return;
    final acc = SavedAccount(
      uid: uid,
      name: (user['name'] ?? '') as String,
      account: (user['account'] ?? '') as String,
      avatar: (user['avatar'] ?? '') as String,
      token: token,
    );
    final list = await loadAccounts();
    final next =
        [acc, ...list.where((e) => e.uid != uid)].take(10).toList();
    await _saveAccounts(next);
  }

  /// 切换到历史账号：注入 token + 重连实时通知
  static Future<void> switchTo(SavedAccount acc) async {
    ApiClient.token = acc.token;
    NotifyBus.shared.disconnect();
    NotifyBus.shared.connect(acc.token);
    final sp = await SharedPreferences.getInstance();
    await sp.setString('community_token', acc.token);
  }

  /// 退出登录：清 token + 断开通知（保留历史账号列表）
  static Future<void> logout() async {
    ApiClient.token = null;
    NotifyBus.shared.disconnect();
    final sp = await SharedPreferences.getInstance();
    await sp.remove('community_token');
  }
}
