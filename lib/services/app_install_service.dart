/// 应用市场 · iOS OTA 安装
///
/// iOS 不允许 App 直接安装另一个 App，唯一受支持的方式是让系统安装器
/// （itms-services）拉取 OTA 清单：清单里给出已签名 IPA 的 HTTPS 直链、
/// Bundle ID 与版本号。这里只负责“唤起系统 + 预检清单”，真正的签名校验
/// 由 iOS 完成；未签名或证书失效时系统会弹“无法安装”。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/client.dart';
import '../models/app_market.dart';

@immutable
class AppInstallResult {
  final bool ok;
  final String message;

  const AppInstallResult.ok([this.message = '']) : ok = true;
  const AppInstallResult.fail(this.message) : ok = false;
}

class AppInstallService {
  const AppInstallService._();

  /// 当前是否运行在 iPhone / iPad 上。用 [defaultTargetPlatform] 而不是
  /// `Platform.isIOS`，widget 测试里可以覆盖平台跑 iOS 分支。
  static bool get isIos =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// 只有 iOS 客户端 + iOS 版本 + 已填写 Bundle ID 才能走 OTA。
  static bool canOtaInstall(MarketApp app) =>
      isIos &&
      app.platform.toLowerCase() == 'ios' &&
      app.packageType.toLowerCase() == 'ipa' &&
      app.packageName.trim().isNotEmpty;

  static String manifestUrlFor(MarketApp app) =>
      '${ApiClient.baseUrl}/apps/${app.id}/ios-manifest.plist';

  static Uri otaUriFor(MarketApp app) {
    final manifest = manifestUrlFor(app);
    return Uri.parse(
      'itms-services://?action=download-manifest'
      '&url=${Uri.encodeComponent(manifest)}',
    );
  }

  /// 先预检清单：服务端不可用 / 应用不是 IPA 时直接给文案，
  /// 避免把错误链接丢给 iOS 后只看到系统一句“无法安装”。
  static Future<AppInstallResult> verify(MarketApp app) async {
    if (!canOtaInstall(app)) {
      if (app.platform.toLowerCase() != 'ios' ||
          app.packageType.toLowerCase() != 'ipa') {
        return const AppInstallResult.fail('这个安装包不是 iOS 版本，无法在 iPhone 上安装');
      }
      return const AppInstallResult.fail('该应用未填写 Bundle ID，暂时无法直接安装');
    }
    try {
      final res = await ApiClient.httpClient
          .get(Uri.parse(manifestUrlFor(app)))
          .timeout(const Duration(seconds: 12));
      final body = utf8.decode(res.bodyBytes);
      if (res.statusCode != 200) {
        var message = '安装清单不可用（HTTP ${res.statusCode}）';
        try {
          final decoded = jsonDecode(body);
          if (decoded is Map && decoded['error'] is String) {
            message = decoded['error'] as String;
          }
        } catch (_) {
          // 非 JSON 错误体：保留上面的 HTTP 文案
        }
        return AppInstallResult.fail(message);
      }
      if (!body.contains('<plist') || !body.contains('software-package')) {
        return const AppInstallResult.fail('安装清单内容不正确，请稍后再试');
      }
      return const AppInstallResult.ok();
    } on TimeoutException {
      return const AppInstallResult.fail('获取安装清单超时，请检查网络后重试');
    } catch (e) {
      return AppInstallResult.fail('获取安装清单失败：$e');
    }
  }

  /// 唤起 iOS 系统安装。返回 ok 只代表“已交给系统”，不代表安装成功。
  static Future<AppInstallResult> install(MarketApp app) async {
    if (!isIos) {
      return const AppInstallResult.fail('只能在 iPhone / iPad 上使用系统安装');
    }
    final check = await verify(app);
    if (!check.ok) return check;
    try {
      final launched = await launchUrl(
        otaUriFor(app),
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        return const AppInstallResult.fail(
          '系统没有接受安装请求。可先下载 IPA，再用签名工具安装。',
        );
      }
      return const AppInstallResult.ok('已交给 iOS 系统安装');
    } catch (e) {
      return AppInstallResult.fail('唤起系统安装失败：$e');
    }
  }
}
