import 'package:community_app/models/app_market.dart';
import 'package:flutter_test/flutter_test.dart';

MarketApp _app({
  required String platform,
  required String packageType,
  String storeUrl = '',
}) {
  return MarketApp(
    id: 'x',
    name: '测试应用',
    platform: platform,
    packageType: packageType,
    storeUrl: storeUrl,
  );
}

void main() {
  group('MarketApp.isStore', () {
    test('store 类型始终进入商店', () {
      expect(_app(platform: 'ios', packageType: 'store').isStore, isTrue);
    });

    test('iOS 旧 app 数据带商店链接时按商店处理', () {
      expect(
        _app(
          platform: 'ios',
          packageType: 'app',
          storeUrl: 'https://apps.apple.com/cn/app/id1021094295',
        ).isStore,
        isTrue,
      );
    });

    test('iOS IPA 即使带商店链接仍走安装包', () {
      expect(
        _app(
          platform: 'ios',
          packageType: 'ipa',
          storeUrl: 'https://apps.apple.com/cn/app/id1021094295',
        ).isStore,
        isFalse,
      );
    });

    test('缺少商店链接的旧数据不误判', () {
      expect(_app(platform: 'ios', packageType: 'app').isStore, isFalse);
    });

    test('Android APK 不进入商店', () {
      expect(
        _app(
          platform: 'android',
          packageType: 'apk',
          storeUrl: 'https://play.google.com/store/apps/details?id=x',
        ).isStore,
        isFalse,
      );
    });
  });
}
