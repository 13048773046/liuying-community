// 我的页整页原生视觉回归：MockClient 喂真实接口结构，不连生产。
// 运行：flutter test test/mine_page_golden_test.dart --update-goldens
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
import 'package:community_app/services/notify_bus.dart';

const _today = '2026-11-18';

Map<String, dynamic> _post(String id, String content, int likes) => {
  'id': id,
  'type': 'text',
  'content': content,
  'images': <String>[],
  'likeCount': likes,
  'commentCount': 2,
  'auditStatus': 1,
  'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
  'author': {
    'id': 'u_demo',
    'name': '林晚萤',
    'avatar': '',
    'level': 6,
    'adminLevel': 0,
  },
};

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
  testWidgets('整页原生渲染', (tester) async {
    await _loadFont();
    SharedPreferences.setMockInitialValues({'community_token': 'demo'});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'read' ? 'demo' : null,
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
    ApiClient.httpClient = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/user/me')) {
        return _ok({
          'user': {
            'id': 'u_demo',
            'name': '林晚萤',
            'avatar': '',
            'verified': true,
            'verifiedLabel': '创作者',
            'adminLevel': 0,
            'followers': 1200,
            'followings': 128,
            'likes': 8600,
            'favCount': 36,
            'city': '苏州',
            'signature': '把每一晚的灵感，做成会发光的东西。',
            'background': '',
          },
        });
      }
      if (path.endsWith('/level/me')) {
        return _ok({
          'level': 6,
          'exp': 240,
          'nextThreshold': 300,
          'progress': 0.8,
        });
      }
      if (path.endsWith('/signins')) {
        return _ok({
          'list': [_today],
        });
      }
      if (path.endsWith('/frame/mine')) {
        return _ok({'frameId': ''});
      }
      if (path.endsWith('/member/status')) {
        return _ok({
          'level': 'svip',
          'label': 'SVIP',
          'daysLeft': 123,
          'expiring': false,
          'expire': DateTime(2027, 3, 21).millisecondsSinceEpoch ~/ 1000,
        });
      }
      if (path.endsWith('/apps/mine')) {
        return _ok({
          'list': [
            {
              'id': 'app_pending',
              'name': '待审应用甲',
              'category': '工具',
              'subCategory': '系统',
              'description': '等待审核的应用。',
              'status': 1,
              'statusText': '审核中',
            },
            {
              'id': 'app_rejected',
              'name': '未通过应用乙',
              'category': '效率',
              'subCategory': '笔记',
              'description': '需要修改后重投的应用。',
              'status': 3,
              'statusText': '未通过',
              'rejectReason': '截图不清晰，请补充应用截图',
            },
            {
              'id': 'app_published',
              'name': '已上架应用丙',
              'category': '影音',
              'subCategory': '视频',
              'description': '已经上架的应用。',
              'status': 2,
              'statusText': '已上架',
              'downloadCount': 12,
            },
          ],
        });
      }
      if (path.contains('/posts')) {
        return _ok({
          'list': [
            _post('p1', '雨停之前，把窗外的光收进一杯咖啡里。', 12),
            _post('p2', '玻璃瓶里的夏天，和一段没有寄出的旋律。', 24),
            _post('p3', '今晚的灵感只有一句：慢一点，也很好。', 8),
          ],
          'hasMore': false,
        });
      }
      if (path.endsWith('/favorites')) {
        return _ok({'list': <dynamic>[], 'hasMore': false, 'page': 1});
      }
      return _ok({});
    });

    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final theme = buildImmersiveTheme();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 844),
          padding: EdgeInsets.only(top: 47, bottom: 34),
        ),
        child: MaterialApp(
          theme: theme.copyWith(
            textTheme: theme.textTheme.apply(fontFamily: 'NotoSansCJK'),
          ),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              padding: EdgeInsets.only(top: 47, bottom: 34),
            ),
            child: const MinePage(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('我的'), findsOneWidget);
    expect(find.text('SVIP 会员'), findsOneWidget);
    expect(find.textContaining('1 款审核中', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('1 款未通过', skipOffstage: false), findsOneWidget);
    // 我的页同样只在头像右下角显示认证 V，昵称旁不重复。
    expect(find.byType(VerifiedBadge), findsOneWidget);
    expect(find.text('创作者'), findsNothing);

    await expectLater(
      find.byType(MinePage),
      matchesGoldenFile('goldens/mine_page_native.png'),
    );

    ApiClient.httpClient = http.Client();
  });
}
