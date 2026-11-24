import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/design/tokens.dart';
import 'package:community_app/pages/home/home_page.dart';
import 'package:community_app/services/app_market_bus.dart';

http.Response _ok(Map<String, dynamic> body) => http.Response(
  jsonEncode({'ok': true, ...body}),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  testWidgets('首页从应用市场返回后不重新拉取发现内容', (tester) async {
    SharedPreferences.setMockInitialValues({});
    AppMarketBus.revision.value = 0;
    var topicsCalls = 0;
    ApiClient.httpClient = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/topics/hot')) {
        topicsCalls++;
        return _ok({
          'list': [
            {'name': '夜航', 'postCount': 12},
          ],
        });
      }
      if (path.endsWith('/apps')) {
        return _ok({
          'list': [
            {'id': 'app_home', 'name': '夜航日志', 'icon': ''},
          ],
          'total': 1,
          'page': 1,
          'pageSize': 20,
        });
      }
      if (path.endsWith('/apps/categories')) {
        return _ok({'list': <dynamic>[]});
      }
      if (path.endsWith('/feed')) {
        return _ok({
          'list': [
            for (var i = 0; i < 12; i++)
              {
                'id': 'p$i',
                'type': 'text',
                'content': '首页圆钮底色回归测试内容 $i，足够长以便页面滚动。',
                'created': 1763550000 + i,
                'author': {'id': 'u$i', 'name': '小满', 'avatar': ''},
              },
          ],
          'hasMore': false,
          'page': 1,
        });
      }
      if (path.endsWith('/banners')) {
        return _ok({'list': <dynamic>[]});
      }
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
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(find.text('全部'), findsOneWidget);
    final before = topicsCalls;

    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle(const Duration(milliseconds: 120));
    expect(find.text('应用市场'), findsWidgets);
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle(const Duration(milliseconds: 120));

    // 只是浏览应用市场，首页的话题/应用橱窗不应重新请求，更不能闪骨架。
    expect(topicsCalls, before);
    expect(find.text('应用橱窗'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('圆形搜索与铃铛共用同一底色', (tester) async {
    SharedPreferences.setMockInitialValues({});
    ApiClient.httpClient = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/feed')) {
        return _ok({
          'list': [
            for (var i = 0; i < 12; i++)
              {
                'id': 'p$i',
                'type': 'text',
                'content': '首页圆钮底色回归测试内容 $i，足够长以便页面滚动。',
                'created': 1763550000 + i,
                'author': {'id': 'u$i', 'name': '小满', 'avatar': ''},
              },
          ],
          'hasMore': false,
          'page': 1,
        });
      }
      if (path.endsWith('/banners')) {
        return _ok({'list': <dynamic>[]});
      }
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
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.drag(find.byType(HomePage), const Offset(0, -180));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    final search = tester.widget<Container>(
      find.byKey(const ValueKey('home-mini-search')),
    );
    final bell = tester.widget<Container>(
      find.byKey(const ValueKey('home-notify-button')),
    );
    final searchDecoration = search.decoration! as BoxDecoration;
    final bellDecoration = bell.decoration! as BoxDecoration;
    expect(searchDecoration.color, bellDecoration.color);
    expect(
      searchDecoration.border!.top.color,
      bellDecoration.border!.top.color,
    );
    final searchIcon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const ValueKey('home-mini-search')),
        matching: find.byIcon(Icons.search_rounded),
      ),
    );
    expect(searchIcon.color, const Color(AppColors.textPrimary));
    expect(tester.takeException(), isNull);
  });

}
