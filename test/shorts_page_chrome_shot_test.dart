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
import 'package:community_app/pages/shorts/shorts_page.dart';

Future<void> loadFont() async {
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

Map<String, Object?> post(String id, String text) => {
  'id': id,
  'type': 'text',
  'content': text,
  'images': <String>[],
  'video': '',
  'cover': '',
  'topic': ['夜航手记'],
  'mentions': <String>[],
  'author': {'id': 'u1', 'name': '流萤', 'avatar': ''},
  'music': null,
  'likeCount': 21,
  'commentCount': 3,
  'shareCount': 0,
};

http.Response _json(Object o) => http.Response.bytes(
  utf8.encode(jsonEncode(o)),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

MockClient _client() => MockClient((req) async {
  if (req.url.path.endsWith('/feed')) {
    return _json({
      'ok': true,
      'page': 1,
      'hasMore': false,
      'list': [
        post('s1', '第一页：夜色里留一盏小灯。'),
        post('s2', '第二页：把风声收进耳机。'),
        post('s3', '第三页：明天见。'),
      ],
    });
  }
  return _json({'ok': true, 'list': <Object>[]});
});

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.baseOverride = 'http://test.local/api';
    ApiClient.token = null;
    ApiClient.httpClient = _client();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
  });

  testWidgets('短片页抖音式顶部：搜索/关注推荐/短下划线，无品牌头', (tester) async {
    await loadFont();
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
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
        home: const ShortsPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // 抖音式顶部不再露出品牌签名/左侧页码尺。
    expect(find.text('SHORTS'), findsNothing);
    expect(find.text('流萤短片'), findsNothing);
    expect(find.text('关注'), findsOneWidget);
    expect(find.text('推荐'), findsOneWidget);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);

    // 「推荐」是默认流：下划线 18 宽；「关注」下划线收为 0。
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester
          .getSize(find.byKey(const ValueKey('shorts_tab_underline_1')))
          .width,
      18,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('shorts_tab_underline_0')))
          .width,
      0,
    );
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(ShortsPage),
      matchesGoldenFile('goldens/shorts_page_redesign_390.png'),
    );
  });
}
