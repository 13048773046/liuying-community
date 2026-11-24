// 手机号 / 邮箱单输入框自动识别登录测试。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:community_app/api/client.dart';

void main() {
  tearDown(() {
    ApiClient.baseOverride = null;
    ApiClient.token = null;
    ApiClient.httpClient = http.Client();
  });

  test('手机号规范化与校验', () {
    expect(ApiClient.normalizePhone('+86 138-0013-8000'), '13800138000');
    expect(ApiClient.normalizePhone('8613800138000'), '13800138000');
    expect(ApiClient.isValidPhone('13800138000'), isTrue);
    expect(ApiClient.isValidPhone('12800138000'), isFalse);
    expect(ApiClient.isValidPhone('1380013800'), isFalse);
    expect(ApiClient.isValidEmail('tester@example.com'), isTrue);
  });

  test('手机号验证码发送只走社区 /auth/send-code', () async {
    final calls = <String>[];
    ApiClient.baseOverride = 'http://community.test/api';
    ApiClient.httpClient = MockClient((req) async {
      calls.add(req.url.toString());
      if (req.url.path == '/api/auth/send-code') {
        final b = jsonDecode(req.body);
        expect(b['identifier'], '13800138000');
        expect(b['captcha_id'], 'c1');
        expect(b['captcha_code'], 'ABCD');
        return http.Response(
          '{"ok":true}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    await ApiClient.sendLoginCode('+86 138-0013-8000', const CaptchaAnswer(id: 'c1', code: 'ABCD'));
    expect(calls, hasLength(1));
    expect(calls.single, 'http://community.test/api/auth/send-code');
  });

  test('手机号验证码登录/注册返回 token 与渠道', () async {
    final calls = <String>[];
    ApiClient.baseOverride = 'http://community.test/api';
    ApiClient.httpClient = MockClient((req) async {
      calls.add(req.url.toString());
      if (req.url.path == '/api/auth/login-code') {
        final body = jsonDecode(req.body);
        expect(body['identifier'], '13800138000');
        expect(body['code'], '123456');
        return http.Response(
          jsonEncode({
            'id': 'u-phone',
            'account': '300001',
            'name': '手机用户',
            'token': 'phone-token',
            'login_channel': 'phone',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    final me = await ApiClient.loginCode('13800138000', '123456');
    expect(calls, hasLength(1));
    expect(calls.single, 'http://community.test/api/auth/login-code');
    expect(me['token'], 'phone-token');
    expect(me['login_channel'], 'phone');
  });

  test('邮箱仍走原邮箱验证码发送链路', () async {
    final calls = <String>[];
    ApiClient.baseOverride = 'http://community.test/api';
    ApiClient.httpClient = MockClient((req) async {
      calls.add(req.url.toString());
      if (req.url.path == '/api/auth/send-email-code') {
        return http.Response(
          '{"ok":true}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    await ApiClient.sendLoginCode('tester@example.com', const CaptchaAnswer(id: 'c1', code: 'ABCD'));
    expect(calls.last, 'http://community.test/api/auth/send-email-code');
  });

  test('绑定手机号发送验证码只走邀请手机号接口', () async {
    final calls = <String>[];
    ApiClient.baseOverride = 'http://community.test/api';
    ApiClient.httpClient = MockClient((req) async {
      calls.add(req.url.toString());
      if (req.url.path == '/api/invite/phone/send') {
        final b = jsonDecode(req.body);
        expect(b['phone'], '13800138000');
        expect(b['captcha_id'], 'c1');
        expect(b['captcha_code'], 'ABCD');
        return http.Response(
          '{"ok":true,"sent":true,"expires":300}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    await ApiClient.sendBindPhoneCode('+86 138-0013-8000', const CaptchaAnswer(id: 'c1', code: 'ABCD'));
    expect(calls, hasLength(1));
    expect(calls.single, 'http://community.test/api/invite/phone/send');
  });

  test('绑定手机号确认返回掩码', () async {
    final calls = <String>[];
    ApiClient.baseOverride = 'http://community.test/api';
    ApiClient.httpClient = MockClient((req) async {
      calls.add(req.url.toString());
      if (req.url.path == '/api/invite/phone/confirm') {
        final body = jsonDecode(req.body);
        expect(body['phone'], '13800138000');
        expect(body['code'], '123456');
        return http.Response(
          '{"ok":true,"phone":"138****8000","valid":{"ok":true}}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    final j = await ApiClient.confirmBindPhone('13800138000', '123456');
    expect(calls, hasLength(1));
    expect(calls.single, 'http://community.test/api/invite/phone/confirm');
    expect(j['phone'], '138****8000');
  });
}
