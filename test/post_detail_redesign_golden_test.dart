import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'path_provider_mock.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/design/spotlight_coach.dart';
import 'package:community_app/models/feed_item.dart' show debugTimeAgoNow;
import 'package:community_app/pages/post/post_detail.dart';

Future<void> _loadFont(String name, String path) async {
  final f = File(path);
  if (!f.existsSync()) return;
  final bytes = await f.readAsBytes();
  final loader = FontLoader(name)
    ..addFont(Future.value(ByteData.view(bytes.buffer)));
  await loader.load();
}

Future<void> _loadAll() async {
  await _loadFont('LAT', '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf');
  await _loadFont('NotoSansSC', 'assets/fonts/NotoSansSC-Regular.otf');
  await _loadFont(
    'CJK',
    '/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf',
  );
  await _loadFont(
    'MaterialIcons',
    '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
}

// 详情页时间文案参与 golden；固定时钟，避免跨天运行时日期变化导致假失败。
final _fixedNow = DateTime(2026, 11, 21, 10);

int _tsAgo(int hours) =>
    _fixedNow.subtract(Duration(hours: hours)).millisecondsSinceEpoch ~/ 1000;

http.Response _json(Object o) => http.Response.bytes(
  utf8.encode(jsonEncode(o)),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

MockClient _client() => MockClient((req) async {
  final p = req.url.path;
  if (p.endsWith('/post/p_redesign')) {
    return _json({
      'ok': true,
      'post': {
        'id': 'p_redesign',
        'type': 'text',
        'content':
            '把夜晚留给安静的人。\n\n今天重新整理了一版帖子详情，不再把信息堆在一条直线上，而是让封面、署名、正文和讨论各自有呼吸。',
        'images': <String>[],
        'topic': ['夜晚写作', '界面重构'],
        'likeCount': 168,
        'commentCount': 2,
        'shareCount': 7,
        'liked': false,
        'faved': false,
        'later': false,
        'created': _tsAgo(22),
        'author': {
          'id': '',
          'name': '林晚萤',
          'avatar': '',
          'level': 6,
          'adminLevel': 0,
          'frameId': '',
        },
        'music': null,
        'poll': null,
      },
    });
  }
  if (p.endsWith('/post/p_redesign/comments')) {
    return _json({
      'ok': true,
      'hasMore': false,
      'list': [
        {
          'id': 'c1',
          'content': '这一版层级清楚很多，封面和正文终于不是挤在一起了。',
          'created': _tsAgo(22),
          'likeCount': 12,
          'liked': false,
          'author': {'id': 'u_a', 'name': '眠山', 'avatar': '', 'adminLevel': 0},
        },
        {
          'id': 'c2',
          'content': '喜欢“把夜晚留给安静的人”这句话，像一条安静的引子。',
          'created': _tsAgo(22),
          'likeCount': 5,
          'liked': true,
          'author': {'id': 'u_b', 'name': '小满', 'avatar': '', 'adminLevel': 0},
        },
      ],
    });
  }
  if (p.endsWith('/topics')) {
    return _json({
      'ok': true,
      'list': [
        {'name': '夜晚写作', 'count': 42},
        {'name': '界面重构', 'count': 9},
      ],
    });
  }
  return _json({'ok': true, 'list': []});
});

void main() {
  mockPathProvider();
  setUpAll(_loadAll);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.baseOverride = 'http://test.local/api';
    ApiClient.token = 'tok';
    ApiClient.userId = '';
    ApiClient.httpClient = _client();
    debugTimeAgoNow = _fixedNow;
    addTearDown(() => debugTimeAgoNow = null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
  });

  testWidgets('帖子详情重构 390 宽', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildImmersiveTheme().copyWith(
          textTheme: buildImmersiveTheme().textTheme.apply(
            fontFamily: 'NotoSansSC',
          ),
        ),
        home: const PostDetailPage(postId: 'p_redesign'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 500));

    expect(tester.takeException(), isNull);
    expect(find.text('帖子信息'), findsOneWidget);
    expect(find.textContaining('夜晚写作'), findsWidgets);
    expect(find.text('讨论'), findsOneWidget);

    await expectLater(
      find.byType(PostDetailPage),
      matchesGoldenFile('goldens/post_detail_redesign_390.png'),
    );

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -560));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(PostDetailPage),
      matchesGoldenFile('goldens/post_detail_redesign_comments_390.png'),
    );
    // CachedNetworkImage 的缓存清理 timer 是 10 秒；测试结束前让它跑完，
    // 否则 widget 树销毁后还会报 "Timer is still pending"。
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
  });

  testWidgets('帖子详情重构 320 窄屏无溢出', (tester) async {
    tester.view.physicalSize = const Size(320 * 3, 700 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildImmersiveTheme().copyWith(
          textTheme: buildImmersiveTheme().textTheme.apply(
            fontFamily: 'NotoSansSC',
          ),
        ),
        home: const PostDetailPage(postId: 'p_redesign'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
  });

  testWidgets('帖子详情首启聚光灯引导 390 宽', (tester) async {
    SpotlightFlags.postActions = true;
    addTearDown(() => SpotlightFlags.postActions = false);
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildImmersiveTheme().copyWith(
          textTheme: buildImmersiveTheme().textTheme.apply(
            fontFamily: 'NotoSansSC',
          ),
        ),
        home: const PostDetailPage(postId: 'p_redesign'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.text('1/3'), findsOneWidget);
    expect(find.text('先留下你的回应'), findsOneWidget);
    await expectLater(
      find.byType(PostDetailPage),
      matchesGoldenFile('goldens/spotlight_post_dock_390.png'),
    );

    await tester.tap(find.text('下一步'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(tester.takeException(), isNull);
    expect(find.text('2/3'), findsOneWidget);
    expect(find.text('点亮喜欢'), findsOneWidget);
    await expectLater(
      find.byType(PostDetailPage),
      matchesGoldenFile('goldens/spotlight_post_dock_step2_390.png'),
    );

    await tester.tap(find.text('下一步'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(tester.takeException(), isNull);
    expect(find.text('3/3'), findsOneWidget);
    expect(find.text('分享给同频的人'), findsOneWidget);
    await expectLater(
      find.byType(PostDetailPage),
      matchesGoldenFile('goldens/spotlight_post_dock_step3_390.png'),
    );

    await tester.tap(find.text('知道了'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('3/3'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('post_actions_guide_v1_seen'), isTrue);
  });

  testWidgets('帖子详情聚光灯 320 窄屏无溢出', (tester) async {
    SpotlightFlags.postActions = true;
    addTearDown(() => SpotlightFlags.postActions = false);
    tester.view.physicalSize = const Size(320 * 3, 700 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildImmersiveTheme().copyWith(
          textTheme: buildImmersiveTheme().textTheme.apply(
            fontFamily: 'NotoSansSC',
          ),
        ),
        home: const PostDetailPage(postId: 'p_redesign'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(find.text('1/3'), findsOneWidget);
  });
}
