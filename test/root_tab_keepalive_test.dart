import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/pages/home/home_page.dart';
import 'package:community_app/pages/mine/mine_page.dart';
import 'package:community_app/pages/root_page.dart';
import 'package:community_app/services/notify_bus.dart';

http.Response _ok(Map<String, dynamic> body) => http.Response(
  jsonEncode({'ok': true, ...body}),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'community_token': 't'});
    NotifyBus.enabled = false;
    NotifyBus.shared.clearUnread();
    NotifyBus.shared.clearDmUnread();
    NotifyBus.shared.clearOfficialUnread();
    ApiClient.token = 't';
    ApiClient.userId = 'me';
  });
  tearDown(() {
    ApiClient.httpClient = http.Client();
    NotifyBus.shared.clearUnread();
    NotifyBus.shared.clearDmUnread();
    NotifyBus.shared.clearOfficialUnread();
  });

  testWidgets('首页↔我的来回切：页面常驻、滚动不丢、不重新请求 feed', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    var feedCalls = 0;
    ApiClient.httpClient = MockClient((request) async {
      final p = request.url.path;
      if (p.endsWith('/feed') && request.url.queryParameters['size'] == '10') {
        feedCalls++;
        return _ok({'list': [], 'hasMore': false, 'page': 1});
      }
      if (p.endsWith('/topics/hot')) return _ok({'list': []});
      if (p.endsWith('/apps')) return _ok({'list': [], 'hasMore': false});
      return _ok({'list': [], 'hasMore': false});
    });

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          fontFamily: 'LAT',
          fontFamilyFallback: const ['CJK'],
        ),
        home: const RootPage(),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(feedCalls, 1);
    final homeState = tester.state<State<HomePage>>(
      find.byType(HomePage, skipOffstage: false),
    );
    // P0-B：冷启动只建首页，其余 tab 首次切到时才初始化。
    expect(
      find.byType(MinePage, skipOffstage: false),
      findsNothing,
      reason: '冷启动不应同时构建我的页',
    );

    // 先让首页滚动一段，记录偏移；切走再切回来必须原样保留。
    final homeScrollable = find.descendant(
      of: find.byType(HomePage),
      matching: find.byType(Scrollable),
    );
    expect(homeScrollable, findsWidgets);
    await tester.drag(homeScrollable.first, const Offset(0, -240));
    await tester.pump(const Duration(milliseconds: 300));
    final before = tester
        .state<ScrollableState>(homeScrollable.first)
        .position
        .pixels;

    final height =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    await tester.tapAt(Offset(width * 0.88, height - 22));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    expect(find.byType(HomePage, skipOffstage: false), findsOneWidget);
    final mineState = tester.state<State<MinePage>>(
      find.byType(MinePage, skipOffstage: false),
    );
    expect(
      identical(
        tester.state<State<MinePage>>(
          find.byType(MinePage, skipOffstage: false),
        ),
        mineState,
      ),
      isTrue,
      reason: '我的页 State 必须原地保留',
    );
    expect(feedCalls, 1, reason: '切到我的不应刷新首页 feed');

    await tester.tapAt(Offset(width * 0.1, height - 22));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    expect(find.byType(HomePage), findsOneWidget);
    expect(
      identical(
        tester.state<State<HomePage>>(
          find.byType(HomePage, skipOffstage: false),
        ),
        homeState,
      ),
      isTrue,
      reason: '切回首页必须是同一个 State，不能重建',
    );
    final after = tester
        .state<ScrollableState>(homeScrollable.first)
        .position
        .pixels;
    expect(after, closeTo(before, 0.5), reason: '切回来应停在原滚动位置');
    expect(feedCalls, 1, reason: '切回首页不应重新请求 feed');
    expect(tester.takeException(), isNull);
  });
}
