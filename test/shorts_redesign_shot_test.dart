import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/config.dart';
import 'package:community_app/design/tokens.dart';
import 'package:community_app/models/feed_item.dart';
import 'package:community_app/pages/shorts/video_card.dart';

FeedItem textPost() => FeedItem.fromJson({
  'id': 'short-ui-1',
  'type': 'text',
  'content': '夜里写下的句子，会在某个清晨自己发光。\n今天也要好好生活。',
  'reason': '因为你常看「夜航手记」',
  'images': [],
  'video': '',
  'cover': '',
  'topic': ['夜航手记'],
  'mentions': [],
  'author': {
    'id': 'u1',
    'name': '流萤',
    'avatar': '',
    'adminLevel': 1,
    'isAdmin': true,
    'adminName': '管理员',
  },
  'music': '{"url": "https://x.example/m.m4a", "name": "夜航", "cover": ""}',
  'likeCount': 128,
  'commentCount': 9,
  'shareCount': 3,
});

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

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
  });

  testWidgets('短片新界面：右侧互动/左下作者文案/旋转唱片', (tester) async {
    await loadFont();
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildImmersiveTheme().copyWith(
          textTheme: buildImmersiveTheme().textTheme.apply(
            fontFamily: 'NotoSansCJK',
          ),
        ),
        home: Scaffold(
          body: VideoCard(
            item: textPost(),
            isActive: false,
            index: 0,
            total: 5,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    // 不再有玻璃大卡和页码/详情入口。
    expect(find.text('01 / 05  ·  流萤短片'), findsNothing);
    expect(find.text('详情'), findsNothing);
    // 左下作者文案、推荐理由、原声行仍在；管理员身份只在名字旁的小胶囊。
    expect(find.text('@流萤'), findsOneWidget);
    expect(find.text('管理员'), findsOneWidget);
    expect(find.text('因为你常看「夜航手记」'), findsOneWidget);
    expect(find.text('原声 · 夜航'), findsOneWidget);
    // 纯文字帖的正文只在大屏中央出现一次，左下不重复；也没有「展开」。
    expect(find.textContaining('夜里写下的句子'), findsOneWidget);
    expect(find.text('展开'), findsNothing);
    // 右侧互动栏用语义标签暴露真实动作，图标不再套玻璃胶囊。
    bool hasSemantics(String label) => tester
        .widgetList<Semantics>(find.byType(Semantics))
        .any((w) => w.properties.label == label);
    expect(hasSemantics('点赞'), isTrue);
    expect(hasSemantics('评论'), isTrue);
    expect(hasSemantics('收藏'), isTrue);
    expect(hasSemantics('分享'), isTrue);
    // 右下角不再挂声音按钮（静音入口已移到顶部右侧）。
    expect(find.byIcon(Icons.volume_up_rounded), findsNothing);
    expect(find.byIcon(Icons.volume_off_rounded), findsNothing);
    // 作者头像按 uid 拼真实头像地址，而不是直接拿数据库文件名当 URL。
    final avatars = tester
        .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .where((w) => w.imageUrl == avatarUrlOf('u1'));
    expect(avatars, isNotEmpty);

    await expectLater(
      find.byType(VideoCard),
      matchesGoldenFile('goldens/shorts_redesign_390.png'),
    );
  });

  testWidgets('双击点赞：中央弹出大爱心并落库', (tester) async {
    final oldClient = ApiClient.httpClient;
    ApiClient.token = 't';
    ApiClient.httpClient = MockClient((request) async {
      return http.Response(
        '{"ok":true,"liked":true,"likeCount":129}',
        200,
        headers: const {'content-type': 'application/json'},
      );
    });
    addTearDown(() {
      ApiClient.token = null;
      ApiClient.httpClient = oldClient;
    });
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildImmersiveTheme().copyWith(
          textTheme: buildImmersiveTheme().textTheme.apply(
            fontFamily: 'NotoSansCJK',
          ),
        ),
        home: Scaffold(
          body: VideoCard(item: textPost(), isActive: true, index: 0, total: 5),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final center = tester.getCenter(find.byType(VideoCard));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.byKey(const ValueKey('burst_1')), findsOneWidget);
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关注按钮：补拉关系、点击落库并收起加号', (tester) async {
    final oldClient = ApiClient.httpClient;
    ApiClient.token = 't';
    var profileCalls = 0;
    var followCalls = 0;
    ApiClient.httpClient = MockClient((request) async {
      final path = request.url.path;
      final headers = {'content-type': 'application/json'};
      if (path.endsWith('/user/u1/profile')) {
        profileCalls++;
        return http.Response(
          '{"ok":true,"following":false}',
          200,
          headers: headers,
        );
      }
      if (path.endsWith('/user/u1/follow')) {
        followCalls++;
        return http.Response(
          '{"ok":true,"following":true}',
          200,
          headers: headers,
        );
      }
      return http.Response(
        '{"ok":false,"error":"unexpected"}',
        404,
        headers: headers,
      );
    });
    addTearDown(() {
      ApiClient.token = null;
      ApiClient.httpClient = oldClient;
    });
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildImmersiveTheme().copyWith(
          textTheme: buildImmersiveTheme().textTheme.apply(
            fontFamily: 'NotoSansCJK',
          ),
        ),
        home: Scaffold(
          body: VideoCard(item: textPost(), isActive: true, index: 0, total: 5),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(profileCalls, 1, reason: '激活卡片应补拉一次关注关系');
    expect(find.byKey(const ValueKey('follow_plus')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('follow_plus')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(followCalls, 1, reason: '点击加号应调用真实关注接口');
    expect(
      find.byKey(const ValueKey('follow_plus')),
      findsNothing,
      reason: '关注成功后加号应收起',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('短视频 320 窄屏：顶部/互动/文案不溢出', (tester) async {
    await loadFont();
    tester.view.physicalSize = const Size(960, 1704);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildImmersiveTheme().copyWith(
          textTheme: buildImmersiveTheme().textTheme.apply(
            fontFamily: 'NotoSansCJK',
          ),
        ),
        home: Scaffold(
          body: VideoCard(
            item: textPost(),
            isActive: false,
            index: 0,
            total: 5,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.text('@流萤'), findsOneWidget);
    expect(find.text('推荐'), findsNothing);
    await expectLater(
      find.byType(VideoCard),
      matchesGoldenFile('goldens/shorts_redesign_320.png'),
    );
  });
}
