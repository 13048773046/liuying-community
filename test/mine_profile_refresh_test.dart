// 我的页资料 / 会员 / 账号切换刷新回归：不连生产，MockClient 按 token 返回不同用户。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/design/tokens.dart';
import 'package:community_app/pages/mine/mine_page.dart';
import 'package:community_app/services/auth_session.dart';
import 'package:community_app/services/notify_bus.dart';
import 'package:community_app/services/user_data_bus.dart';

http.Response _ok(Map<String, dynamic> body) => http.Response(
  jsonEncode({'ok': true, ...body}),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Future<void> _loadFont() async {
  final ico = File(
    '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (ico.existsSync()) {
    try {
      final l = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(ico.readAsBytesSync())));
      await l.load();
    } catch (_) {}
  }
  for (final path in [
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    '/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf',
  ]) {
    final f = File(path);
    if (!f.existsSync()) continue;
    try {
      final loader = FontLoader('NotoSansCJK')
        ..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      return;
    } catch (_) {}
  }
}

void main() {
  testWidgets('资料、头像、会员和切换账号后都刷新', (tester) async {
    await _loadFont();
    SharedPreferences.setMockInitialValues({'community_token': 'tokenA'});
    var secureToken = 'tokenA';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            switch (call.method) {
              case 'read':
                return secureToken;
              case 'write':
                final args = Map<String, dynamic>.from(call.arguments as Map);
                if (args['key'] == 'community_token') {
                  secureToken = (args['value'] ?? '').toString();
                }
                return null;
              case 'delete':
                secureToken = '';
                return null;
            }
            return null;
          },
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            null,
          ),
    );
    NotifyBus.enabled = false;
    addTearDown(() => NotifyBus.enabled = true);

    var userName = '甲用户';
    var avatar = '';
    Map<String, dynamic>? member;

    ApiClient.httpClient = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/user/me')) {
        final isB = ApiClient.token == 'tokenB';
        return _ok({
          'user': {
            'id': isB ? 'u_b' : 'u_a',
            'name': isB ? '乙用户' : userName,
            'avatar': isB ? '' : avatar,
            'verified': false,
            'adminLevel': 0,
            'followers': 0,
            'followings': 0,
            'likes': 0,
            'favCount': 0,
            'city': '',
            'signature': '',
            'background': '',
          },
        });
      }
      if (path.endsWith('/level/me')) {
        return _ok({'level': 1, 'exp': 0, 'nextThreshold': 100, 'progress': 0});
      }
      if (path.endsWith('/signins')) return _ok({'list': <dynamic>[]});
      if (path.endsWith('/frame/mine')) return _ok({'frameId': ''});
      if (path.endsWith('/member/status')) {
        return _ok(member ?? <String, dynamic>{});
      }
      if (path.endsWith('/apps/mine')) {
        return _ok({'list': <dynamic>[]});
      }
      if (path.contains('/posts')) {
        return _ok({'list': <dynamic>[], 'hasMore': false});
      }
      if (path.endsWith('/favorites')) {
        return _ok({'list': <dynamic>[], 'hasMore': false, 'page': 1});
      }
      return _ok({});
    });
    addTearDown(() => ApiClient.httpClient = http.Client());

    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildImmersiveTheme().copyWith(
          textTheme: buildImmersiveTheme().textTheme.apply(
            fontFamily: 'NotoSansCJK',
          ),
        ),
        home: const MediaQuery(
          data: MediaQueryData(
            size: Size(390, 844),
            padding: EdgeInsets.only(top: 47, bottom: 34),
          ),
          child: MinePage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('甲用户'), findsOneWidget);

    // 编辑资料 / 上传头像后：资料与头像地址都要变化，不能命中旧图缓存。
    userName = '甲用户改名';
    avatar = 'u_a_avatar.jpg';
    UserDataBus.touch();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('甲用户改名'), findsOneWidget);
    final avatarWidget = tester.widget<AppAvatar>(find.byType(AppAvatar).first);
    expect(avatarWidget.url, contains('?v='));

    // 开通会员后：会员状态带立即变为 SVIP 会员。
    member = {
      'level': 'svip',
      'label': 'SVIP',
      'daysLeft': 365,
      'expiring': false,
      'expire': 1800000000,
    };
    UserDataBus.touch();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('SVIP 会员'), findsOneWidget);

    // 切换账号后：不能残留上一个账号的昵称/资料。
    await AuthSession.switchTo(
      const SavedAccount(
        uid: 'u_b',
        name: '乙用户',
        account: '200002',
        avatar: '',
        token: 'tokenB',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('乙用户'), findsOneWidget);
    expect(find.text('甲用户改名'), findsNothing);
  });
}
