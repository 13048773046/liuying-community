import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/tokens.dart';
import 'package:community_app/pages/root_page.dart';
import 'package:community_app/services/notify_bus.dart';

Map<String, Object?> _post(String id, String text) => {
  'id': id,
  'type': 'text',
  'content': text,
  'images': <String>[],
  'video': '',
  'cover': '',
  'topic': ['夜航手记'],
  'mentions': <String>[],
  'author': {'id': 'u1', 'name': '流萤', 'avatar': '', 'adminLevel': 1},
  'music': null,
  'likeCount': 21,
  'commentCount': 3,
  'shareCount': 1,
};

http.Response _json(Object o) => http.Response.bytes(
  utf8.encode(jsonEncode(o)),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Future<void> _loadFont(String name, String path) async {
  final f = File(path);
  if (!f.existsSync()) return;
  final bytes = await f.readAsBytes();
  final loader = FontLoader(name)
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}

Future<void> _loadFonts() async {
  await _loadFont(
    'NotoSansCJK',
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  );
  await _loadFont(
    'MaterialIcons',
    '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({'community_token': 't'});
    NotifyBus.enabled = false;
    NotifyBus.shared.clearUnread();
    NotifyBus.shared.clearDmUnread();
    NotifyBus.shared.clearOfficialUnread();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
    ApiClient.token = 't';
    ApiClient.userId = 'me';
    ApiClient.baseOverride = 'http://test.local/api';
    ApiClient.httpClient = MockClient((request) async {
      final p = request.url.path;
      if (p.endsWith('/feed')) {
        return _json({
          'ok': true,
          'page': 1,
          'hasMore': false,
          'list': [_post('s1', '第一页：夜色里留一盏小灯。'), _post('s2', '第二页：把风声收进耳机。')],
        });
      }
      if (p.endsWith('/notifications/unread')) {
        return _json({
          'ok': true,
          'unread': 0,
          'officialUnread': 0,
          'byType': <String, int>{},
        });
      }
      if (p.endsWith('/dm/unread')) {
        return _json({'ok': true, 'unread': 0});
      }
      return _json({'ok': true, 'list': <Object>[], 'hasMore': false});
    });
  });
  tearDown(() {
    ApiClient.httpClient = http.Client();
    ApiClient.baseOverride = null;
  });

  testWidgets('短视频页整体：抖音式顶部 + 深色底栏', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildImmersiveTheme().copyWith(
          textTheme: buildImmersiveTheme().textTheme.apply(
            fontFamily: 'NotoSansCJK',
          ),
        ),
        home: const RootPage(),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 中间「＋」→ 刷短视频
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.tap(find.text('刷短视频').last);
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(find.text('关注'), findsOneWidget);
    expect(find.text('推荐'), findsOneWidget);
    expect(find.text('@流萤'), findsOneWidget);
    expect(find.text('SHORTS'), findsNothing);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    // 底栏五个入口仍在，且短视频页不再出现发丝分隔线造成的断层。
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    final nav = tester.widget<Container>(
      find.byKey(const ValueKey('bottom_nav_shell')),
    );
    final navDecoration = nav.decoration! as BoxDecoration;
    expect(navDecoration.border, isNull, reason: '短视频页底栏去发丝线');
    expect(navDecoration.color, const Color(0xF0000000));
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(RootPage),
      matchesGoldenFile('goldens/shorts_root_390.png'),
    );
  });
}
