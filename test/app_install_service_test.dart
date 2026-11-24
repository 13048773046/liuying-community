/// iOS OTA 安装 URL / 平台守卫的单元测试。
library;

import 'package:community_app/api/client.dart';
import 'package:community_app/models/app_market.dart';
import 'package:community_app/services/app_install_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

MarketApp _app({
  String platform = 'ios',
  String packageType = 'ipa',
  String packageName = 'com.liuying.community',
}) => MarketApp(
  id: 'app_abc123',
  name: '流萤社区',
  platform: platform,
  packageType: packageType,
  packageName: packageName,
  version: '0.9.28',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ApiClient.baseOverride = 'https://www.yosar.cloud/community/api';
  });

  tearDown(() {
    ApiClient.baseOverride = null;
    debugDefaultTargetPlatformOverride = null;
  });

  test('iOS + IPA 才允许 OTA，Android 包被拒绝', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(AppInstallService.canOtaInstall(_app()), isTrue);
    expect(
      AppInstallService.canOtaInstall(_app(packageType: 'apk')),
      isFalse,
    );
    expect(
      AppInstallService.canOtaInstall(_app(packageName: '')),
      isFalse,
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(AppInstallService.canOtaInstall(_app()), isFalse);
  });

  test('清单地址与 itms-services URL 编码正确', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final app = _app();
    expect(
      AppInstallService.manifestUrlFor(app),
      'https://www.yosar.cloud/community/api/apps/app_abc123/ios-manifest.plist',
    );
    final uri = AppInstallService.otaUriFor(app);
    expect(uri.scheme, 'itms-services');
    expect(uri.host, '');
    expect(uri.queryParameters['action'], 'download-manifest');
    expect(
      uri.queryParameters['url'],
      'https://www.yosar.cloud/community/api/apps/app_abc123/ios-manifest.plist',
    );
  });

  test('非 iOS 平台直接拒绝安装，不发起网络请求', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final result = await AppInstallService.install(_app());
    expect(result.ok, isFalse);
    expect(result.message, contains('iPhone'));
  });
}
