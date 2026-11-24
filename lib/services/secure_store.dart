/// 流萤社区 · 敏感本地数据存储
///
/// token / 多账号会话不落 SharedPreferences（明文 XML/plist 可被备份、root、
/// 文件读取带走），统一走 Keychain（iOS）/ Keystore（Android）。
/// 首次启动会把旧版 SharedPreferences 里的 token 迁走并删除旧 key。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SecureStoreException implements Exception {
  final String message;
  const SecureStoreException(this.message);
  @override
  String toString() => message;
}

class SecureStore {
  SecureStore._();

  // iOS：仅本机、首次解锁后可读，禁止 iCloud 钥匙串同步；
  // Android：保持插件默认的 Keystore 加密实现，避免切换存储后端导致现有登录态丢失。
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
    aOptions: AndroidOptions(resetOnError: false),
  );

  static const tokenKey = 'community_token';
  static const accountsKey = 'community_saved_accounts';

  /// 读取敏感值。只读 Keychain/Keystore；安全存储不可用时返回 null，
  /// 不再从 SharedPreferences 明文兜底，避免设备备份/root 后被直接读走。
  static Future<String?> read(String key) async {
    try {
      final value = await _storage.read(key: key);
      if (value == null || value.isEmpty) return null;
      await _removeLegacy(key);
      return value;
    } catch (_) {
      return null;
    }
  }

  /// 写入敏感值。写失败直接抛错，由登录页提示用户，绝不降级为明文。
  static Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
      await _removeLegacy(key);
    } catch (e) {
      throw const SecureStoreException(
        '设备安全存储不可用，无法安全保存登录凭证。请检查系统钥匙串/Keystore 后重试。',
      );
    }
  }

  static Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {}
    await _removeLegacy(key);
  }

  static Future<void> clearAuth() async {
    await delete(tokenKey);
    await delete(accountsKey);
  }

  /// 启动时主动迁移旧版明文数据：只有安全写入成功后才删除明文，
  /// 写失败则保留旧值等待下次启动重试，避免用户直接掉登录态。
  static Future<void> migrateLegacy() async {
    for (final key in const [tokenKey, accountsKey]) {
      final legacy = await _legacyRead(key);
      if (legacy == null || legacy.isEmpty) {
        await _removeLegacy(key);
        continue;
      }
      try {
        await _storage.write(key: key, value: legacy);
        await _removeLegacy(key);
      } catch (_) {
        // 保留旧值，下次启动继续迁移；不会在新写入路径降级。
      }
    }
  }

  static Future<String?> _legacyRead(String key) async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getString(key);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _removeLegacy(String key) async {
    try {
      final sp = await SharedPreferences.getInstance();
      if (sp.containsKey(key)) await sp.remove(key);
    } catch (_) {}
  }
}
