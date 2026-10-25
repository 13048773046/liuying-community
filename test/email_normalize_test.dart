import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/api/client.dart';

void main() {
  group('邮箱规范化与本地校验（对齐服务端 /api/send-email-code 契约）', () {
    test('全角字符转半角', () {
      expect(ApiClient.normalizeEmail('ＡＢＣ＠ＱＱ.ＣＯＭ'), 'abc@qq.com');
      expect(ApiClient.normalizeEmail('ｕｓｅｒ@１２６．ｃｏｍ'), 'user@126.com');
    });

    test('去除首尾/内部空格与全角空格', () {
      expect(ApiClient.normalizeEmail('  abc@qq.com  '), 'abc@qq.com');
      expect(ApiClient.normalizeEmail('abc @ qq.com'), 'abc@qq.com');
      expect(ApiClient.normalizeEmail('abc\u3000@qq.com'), 'abc@qq.com');
    });

    test('去除零宽字符与 BOM', () {
      expect(ApiClient.normalizeEmail('a\u200Bb@qq.com'), 'ab@qq.com');
      expect(ApiClient.normalizeEmail('\uFEFFabc@qq.com'), 'abc@qq.com');
    });

    test('统一小写', () {
      expect(ApiClient.normalizeEmail('ABC@QQ.COM'), 'abc@qq.com');
    });

    test('规范化后合法邮箱通过本地校验', () {
      expect(ApiClient.isValidEmail(ApiClient.normalizeEmail('ＡＢＣ＠ＱＱ.ＣＯＭ')), true);
      expect(ApiClient.isValidEmail(ApiClient.normalizeEmail('user.name+tag@mail.com')), true);
    });

    test('非法字符邮箱被本地校验拦截', () {
      expect(ApiClient.isValidEmail('abc#x@qq.com'), false);
      expect(ApiClient.isValidEmail('abc!x@qq.com'), false);
      expect(ApiClient.isValidEmail('abc@qq_com'), false);
      expect(ApiClient.isValidEmail('no-at-sign.com'), false);
      expect(ApiClient.isValidEmail('abc@qq'), false);
    });
  });
}
