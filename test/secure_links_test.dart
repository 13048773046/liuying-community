import 'package:community_app/services/secure_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('httpsUri', () {
    test('只接受干净的 HTTPS 外链', () {
      expect(SecureLinks.httpsUri('https://example.com/a?b=1'), isNotNull);
      expect(SecureLinks.httpsUri('http://example.com/a'), isNull);
      expect(SecureLinks.httpsUri('javascript:alert(1)'), isNull);
      expect(SecureLinks.httpsUri('intent://scan/#Intent;scheme=zxing;end'), isNull);
      expect(SecureLinks.httpsUri('https://user:pass@example.com/'), isNull);
      expect(SecureLinks.httpsUri('https:///missing-host'), isNull);
      expect(SecureLinks.httpsUri('  '), isNull);
    });

    test('允许白名单及其子域，拒绝其他主机', () {
      const hosts = {'apps.apple.com'};
      expect(
        SecureLinks.httpsUri('https://apps.apple.com/cn/app/id1', allowedHosts: hosts),
        isNotNull,
      );
      expect(
        SecureLinks.httpsUri('https://evil.apps.apple.com/x', allowedHosts: hosts),
        isNotNull,
      );
      expect(
        SecureLinks.httpsUri('https://apple.com.evil.example/x', allowedHosts: hosts),
        isNull,
      );
    });
  });

  group('isPublicHttpUrl', () {
    test('拒绝回环、内网和元数据地址', () async {
      for (final url in [
        'http://127.0.0.1:8080/',
        'https://127.0.0.1/',
        'http://localhost:8080/',
        'http://10.0.0.1/',
        'http://172.16.0.1/',
        'http://192.168.1.1/',
        'http://169.254.169.254/latest/meta-data/',
        'http://[::1]/',
        'http://0.0.0.0/',
        'http://100.64.0.1/',
      ]) {
        expect(await SecureLinks.isPublicHttpUrl(url), isFalse, reason: url);
      }
    });

    test('拒绝非 HTTP(S) 与带 userinfo 的地址', () async {
      expect(await SecureLinks.isPublicHttpUrl('file:///etc/passwd'), isFalse);
      expect(await SecureLinks.isPublicHttpUrl('ftp://example.com/a'), isFalse);
      expect(await SecureLinks.isPublicHttpUrl('http://user:pass@example.com/'), isFalse);
    });
  });

  group('isTrustedApiOrigin', () {
    test('只允许社区 HTTPS 域名', () {
      expect(
        SecureLinks.isTrustedApiOrigin(Uri.parse('https://www.dbmt999.asia/community/api/media/a.jpg')),
        isTrue,
      );
      expect(
        SecureLinks.isTrustedApiOrigin(Uri.parse('http://www.dbmt999.asia/community/api/media/a.jpg')),
        isFalse,
      );
      expect(
        SecureLinks.isTrustedApiOrigin(Uri.parse('https://evil.example/a.jpg')),
        isFalse,
      );
      expect(
        SecureLinks.isTrustedApiOrigin(Uri.parse('https://www.dbmt999.asia.evil.example/a.jpg')),
        isFalse,
      );
    });
  });
}
