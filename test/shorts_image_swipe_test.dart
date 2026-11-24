import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/config.dart';
import 'package:community_app/models/feed_item.dart';
import 'package:community_app/pages/shorts/video_card.dart';

Widget shortsCard() => MaterialApp(
  theme: ThemeData(brightness: Brightness.dark),
  home: Scaffold(body: VideoCard(item: imgPost(), isActive: true)),
);

bool hasImg(WidgetTester t, String name) => t
    .widgetList(
      find.byWidgetPredicate(
        (w) => w is CachedNetworkImage && w.imageUrl == mediaUrl(name),
      ),
    )
    .isNotEmpty;

FeedItem imgPost() => FeedItem.fromJson({
  'id': 't1',
  'type': 'text',
  'content': '三图测试帖',
  'images': ['a.jpg', 'b.jpg', 'c.jpg'],
  'video': '',
  'cover': '',
  'topic': [],
  'mentions': [],
  'author': {'id': 'u1', 'name': '测试', 'avatar': ''},
  'music': '{"url": "https://x.example/m.m4a", "name": "配乐A", "cover": ""}',
});

void main() {
  setUp(() {
    // 新版 VideoCard 会读 PlaybackPrefs（SharedPreferences），测试需 mock
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
  });

  testWidgets('长按菜单：不感兴趣立即回调并关闭面板', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    var hidden = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(
          body: VideoCard(
            item: imgPost(),
            isActive: false,
            onNotInterested: () => hidden = true,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.longPress(find.byType(VideoCard));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('不感兴趣'), findsOneWidget);
    await tester.tap(find.text('不感兴趣'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(hidden, isTrue, reason: '点击后必须通知外层移除当前内容');
    expect(find.text('不感兴趣'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('多图图集自动轮播：3秒切下一张，最后无缝回第一张无限连续', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(shortsCard());
    await tester.pump(const Duration(milliseconds: 300));
    expect(hasImg(tester, 'a.jpg'), isTrue, reason: '初始显示第1张');

    // 3 秒后自动切第 2 张
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 350));
    expect(hasImg(tester, 'b.jpg'), isTrue, reason: '3秒后应自动切到第2张');

    // 再 3 秒切第 3 张（最后）
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 350));
    expect(hasImg(tester, 'c.jpg'), isTrue, reason: '应自动切到第3张');

    // 再 3 秒：无缝回到第一张，无限连续
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 350));
    expect(hasImg(tester, 'a.jpg'), isTrue, reason: '最后一张后应无缝回到第1张');
    expect(hasImg(tester, 'c.jpg'), isFalse, reason: '不应停在最后一张');
  });

  testWidgets('抖音式分段进度条存在 + 手动滑动切页', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(shortsCard());
    await tester.pump(const Duration(milliseconds: 300));
    // 当前段有进度动画（1 个 FractionallySizedBox）
    expect(
      find.byType(FractionallySizedBox),
      findsOneWidget,
      reason: '当前段应有进度动画',
    );

    // 图集分段进度条也贴底部导航栏上方（导航栏 58 + 5px）。
    final bar = find.byKey(const ValueKey('shorts_image_progress'));
    expect(bar, findsOneWidget);
    final bottom = tester.getBottomLeft(bar).dy;
    expect(bottom, closeTo(844 - 58 - 1, 1.2), reason: '进度条应贴在导航栏上沿');

    // 手动左滑切到第 2 张
    await tester.drag(
      find.byType(PageView),
      const Offset(-400, 0),
      warnIfMissed: false,
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(hasImg(tester, 'b.jpg'), isTrue, reason: '手动滑动应切到第2张');

    // 底部进度条支持点按/拖动切图：点最右段应直接到第 3 张
    final rect = tester.getRect(bar);
    await tester.tapAt(Offset(rect.left + rect.width * 0.85, rect.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(hasImg(tester, 'c.jpg'), isTrue, reason: '拖动条点最右段应切到第3张');
  });
}
