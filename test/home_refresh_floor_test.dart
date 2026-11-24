import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/pages/home/home_page.dart';

http.Response _ok(Map<String, dynamic> body) => http.Response(
  jsonEncode({'ok': true, ...body}),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('首页下拉刷新复用统一入口，刷新 feed 与发现区', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var feedCalls = 0;
    var topicsCalls = 0;
    ApiClient.httpClient = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/feed')) {
        feedCalls++;
        return _ok({
          'list': [
            for (var i = 0; i < 12; i++)
              {
                'id': 'p$i',
                'type': 'text',
                'content': '下拉刷新回归内容 $i，足够长以便页面滚动。',
                'created': 1763550000 + i,
                'author': {'id': 'u$i', 'name': '小满', 'avatar': ''},
              },
          ],
          'hasMore': false,
          'page': 1,
        });
      }
      if (path.endsWith('/topics')) {
        topicsCalls++;
        return _ok({
          'list': [
            {'name': '夜航', 'postCount': 12},
          ],
        });
      }
      if (path.endsWith('/apps')) {
        return _ok({'list': <dynamic>[], 'total': 0, 'page': 1});
      }
      if (path.endsWith('/banners')) return _ok({'list': <dynamic>[]});
      return _ok({});
    });
    addTearDown(() => ApiClient.httpClient = http.Client());

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(theme: buildImmersiveTheme(), home: const HomePage()),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(feedCalls, 1);
    expect(topicsCalls, 1);

    final indicator = tester.state<RefreshIndicatorState>(
      find.byKey(const ValueKey('home-refresh')),
    );
    final refreshFuture = indicator.show();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await refreshFuture;
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    expect(feedCalls, 2, reason: '下拉刷新必须重新拉 feed');
    expect(topicsCalls, 2, reason: '下拉刷新必须同步刷新发现区');
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页下拉超过阈值进二楼，未超过阈值只刷新', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var feedCalls = 0;
    ApiClient.httpClient = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/feed')) {
        feedCalls++;
        return _ok({
          'list': [
            {
              'id': 'p0',
              'type': 'text',
              'content': '二楼入口回归内容。',
              'created': 1763550000,
              'author': {'id': 'u0', 'name': '小满', 'avatar': ''},
            },
          ],
          'hasMore': false,
          'page': 1,
        });
      }
      if (path.endsWith('/topics/hot')) return _ok({'list': <dynamic>[]});
      if (path.endsWith('/apps')) return _ok({'list': <dynamic>[]});
      if (path.endsWith('/banners')) return _ok({'list': <dynamic>[]});
      return _ok({});
    });
    addTearDown(() => ApiClient.httpClient = http.Client());

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(theme: buildImmersiveTheme(), home: const HomePage()),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(feedCalls, 1);

    // 从顶部向下拉过阈值：进入二楼，而不是只触发刷新。
    await tester.dragFrom(const Offset(195, 80), const Offset(0, 420));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(
      find.byKey(const ValueKey('home-floor-open')),
      findsOneWidget,
      reason: '下拉超过阈值应展开二楼',
    );
    expect(
      find.byKey(const ValueKey('home-pull-gap-spinner')),
      findsNothing,
      reason: '进二楼后缝隙加载应完全退场',
    );
    expect(feedCalls, 1, reason: '进二楼时不能偷偷刷新 feed');

    // 二楼内上滑收起，再拉一小段：不应进二楼，手势回到刷新/滚动。
    await tester.dragFrom(const Offset(195, 700), const Offset(0, -500));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(
      find.byKey(const ValueKey('home-floor-open')),
      findsNothing,
      reason: '上滑后二楼应收起',
    );
    await tester.dragFrom(const Offset(195, 80), const Offset(0, 130));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(
      find.byKey(const ValueKey('home-floor-open')),
      findsNothing,
      reason: '未过阈值的下拉不能误开二楼',
    );
    expect(feedCalls, 2, reason: '未过阈值应走刷新，而不是进二楼');

    expect(
      find.byKey(const ValueKey('home-floor-button')),
      findsNothing,
      reason: '二楼只走下拉伸展手势，不保留顶栏按钮入口',
    );
    expect(tester.takeException(), isNull);
  });


  testWidgets('短拉过刷新线但不过二楼主线：只刷新，不进二楼', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var feedCalls = 0;
    ApiClient.httpClient = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/feed')) {
        feedCalls++;
        return _ok({
          'list': [
            {
              'id': 'p0',
              'type': 'text',
              'content': '短拉刷新回归内容。',
              'created': 1763550000,
              'author': {'id': 'u0', 'name': '小满', 'avatar': ''},
            },
          ],
          'hasMore': false,
          'page': 1,
        });
      }
      if (path.endsWith('/topics/hot')) return _ok({'list': <dynamic>[]});
      if (path.endsWith('/apps')) return _ok({'list': <dynamic>[]});
      if (path.endsWith('/banners')) return _ok({'list': <dynamic>[]});
      return _ok({});
    });
    addTearDown(() => ApiClient.httpClient = http.Client());

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(theme: buildImmersiveTheme(), home: const HomePage()),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(feedCalls, 1);

    final gesture = await tester.startGesture(const Offset(195, 80));
    await gesture.moveBy(const Offset(0, 130));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('home-pull-gap')),
      findsOneWidget,
      reason: '下拉时顶部应拉开刷新缝隙',
    );
    expect(
      find.text('松开刷新'),
      findsOneWidget,
      reason: '越过刷新线后提示应变成松开刷新',
    );
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 80));
    expect(
      find.byKey(const ValueKey('home-pull-gap-spinner')),
      findsOneWidget,
      reason: '松手后缝隙应停留并显示加载图标',
    );
    expect(
      find.text('正在刷新'),
      findsOneWidget,
      reason: '松手后缝隙应显示正在刷新',
    );
    expect(feedCalls, 2, reason: '短拉应刷新 feed');
    await tester.pump(const Duration(milliseconds: 520));
    expect(
      find.byKey(const ValueKey('home-pull-gap-spinner')),
      findsNothing,
      reason: '刷新完成后缝隙应自动合上',
    );
    expect(
      find.byKey(const ValueKey('home-floor-open')),
      findsNothing,
      reason: '短拉不能进二楼',
    );
    expect(tester.takeException(), isNull);
  });


  testWidgets('下拉未过刷新线：回弹且不刷新', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var feedCalls = 0;
    ApiClient.httpClient = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/feed')) {
        feedCalls++;
        return _ok({'list': <dynamic>[], 'hasMore': false, 'page': 1});
      }
      if (path.endsWith('/topics/hot')) return _ok({'list': <dynamic>[]});
      if (path.endsWith('/apps')) return _ok({'list': <dynamic>[]});
      if (path.endsWith('/banners')) return _ok({'list': <dynamic>[]});
      return _ok({});
    });
    addTearDown(() => ApiClient.httpClient = http.Client());

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(theme: buildImmersiveTheme(), home: const HomePage()),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(feedCalls, 1);

    final gesture = await tester.startGesture(const Offset(195, 80));
    await gesture.moveBy(const Offset(0, 78));
    await tester.pump();
    expect(find.byKey(const ValueKey('home-pull-gap')), findsOneWidget);
    expect(find.text('下拉刷新'), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(feedCalls, 1, reason: '未过刷新线不能刷新');
    expect(
      find.byKey(const ValueKey('home-floor-open')),
      findsNothing,
      reason: '未过刷新线也不能进二楼',
    );
    expect(
      find.byKey(const ValueKey('home-pull-gap-spinner')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
