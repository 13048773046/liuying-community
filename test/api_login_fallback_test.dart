// 音乐网关不可用时的登录回退：先音乐 /music/api/login，502 后走社区 /auth/login。
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

  test('音乐 502 时自动回退社区登录，且 token 原样返回', () async {
    final calls = <String>[];
    ApiClient.baseOverride = 'http://community.test/api';
    ApiClient.httpClient = MockClient((req) async {
      calls.add(req.url.toString());
      if (req.url.path == '/music/api/login') {
        return http.Response('{"err":"bad gateway"}', 502,
          headers: {'content-type': 'application/json; charset=utf-8'});
      }
      if (req.url.path == '/api/auth/login') {
        return http.Response(
          jsonEncode({
            'id': 'u1',
            'account': 'tester',
            'name': '测试用户',
            'token': 'community-token',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    final me = await ApiClient.login('tester', 'pw');
    expect(calls, hasLength(2));
    expect(calls.first, contains('/music/api/login'));
    expect(calls.last, 'http://community.test/api/auth/login');
    expect(me['token'], 'community-token');
    expect(me['id'], 'u1');
  });

  test('音乐 401 不触发回退，保留密码错误', () async {
    var calls = 0;
    ApiClient.baseOverride = 'http://community.test/api';
    ApiClient.httpClient = MockClient((req) async {
      calls++;
      return http.Response('{"err":"账号或密码错误"}', 401,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });

    await expectLater(
      ApiClient.login('tester', 'bad'),
      throwsA(isA<ApiException>()
          .having((e) => e.code, 'code', 401)
          .having((e) => e.message, 'message', '账号或密码错误')),
    );
    expect(calls, 1);
  });

  test('邮箱验证码发送只走社区并携带人机验证（防止绕过）', () async {
    final calls = <String>[];
    ApiClient.baseOverride = 'http://community.test/api';
    ApiClient.httpClient = MockClient((req) async {
      calls.add(req.url.toString());
      if (req.url.path == '/api/auth/send-email-code') {
        final b = jsonDecode(req.body);
        expect(b['email'], 'tester@example.com');
        expect(b['captcha_id'], 'c1');
        expect(b['captcha_code'], 'ABCD');
        return http.Response('{"ok":true}', 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('{}', 404);
    });

    await ApiClient.sendEmailCode(
      'tester@example.com',
      const CaptchaAnswer(id: 'c1', code: 'ABCD'),
    );
    expect(calls, hasLength(1));
    expect(calls.single, 'http://community.test/api/auth/send-email-code');
  });

  test('邮箱验证码登录：音乐 502 时回退社区并返回 token', () async {
    final calls = <String>[];
    ApiClient.baseOverride = 'http://community.test/api';
    ApiClient.httpClient = MockClient((req) async {
      calls.add(req.url.toString());
      if (req.url.path == '/music/api/login-email') {
        return http.Response('{"err":"bad gateway"}', 502,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      if (req.url.path == '/api/auth/login-email') {
        return http.Response(
          jsonEncode({'id': 'u2', 'account': '200002', 'name': '邮箱用户',
            'token': 'email-token'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    final me = await ApiClient.loginEmail('tester@example.com', '123456');
    expect(calls, hasLength(2));
    expect(calls.first, contains('/music/api/login-email'));
    expect(calls.last, 'http://community.test/api/auth/login-email');
    expect(me['token'], 'email-token');
  });
}
