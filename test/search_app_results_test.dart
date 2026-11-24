/// 搜索页应用结果：搜索词命中应用后，结果页必须有应用分组与可直接进入的应用卡。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/pages/search/search_page.dart';

http.Response _ok(Map<String, dynamic> body) => http.Response(
  jsonEncode({'ok': true, ...body}),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

final Map<String, dynamic> _app = {
  'id': 'app_search_1',
  'name': 'NewPipe 测试版',
  'icon': '',
  'platform': 'android',
  'packageType': 'apk',
  'packageName': 'org.schabi.newpipe.test',
  'version': '0.29.3',
  'category': '影音',
  'subCategory': '视频',
  'categoryId': 'appcat_media',
  'description': '轻量开源的视频客户端，用来验证应用搜索结果。',
  'reason': '因为你常逛「影音」分类',
  'downloadCount': 2,
  'rating': 0,
  'ratingCount': 0,
};

void main() {
  testWidgets('搜索 NewPipe 命中应用并显示应用分组', (tester) async {
    SharedPreferences.setMockInitialValues({});
    ApiClient.httpClient = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/search/hot')) {
        return _ok({
          'list': [
            {'q': 'NewPipe'},
            {'q': '效率工具'},
          ],
        });
      }
      if (path.endsWith('/search/suggest')) {
        return _ok({'topics': <dynamic>[], 'users': <dynamic>[]});
      }
      if (path.endsWith('/apps')) {
        return _ok({
          'list': [_app],
          'total': 1,
          'page': 1,
          'pageSize': 20,
        });
      }
      if (path.endsWith('/search')) {
        return _ok({
          'posts': <dynamic>[],
          'videos': <dynamic>[],
          'users': <dynamic>[],
          'topics': <dynamic>[],
        });
      }
      if (path.endsWith('/feed')) {
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
        theme: buildImmersiveTheme(),
        home: const SearchPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    await tester.enterText(find.byType(TextField), 'NewPipe');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1200));

    expect(find.text('相关应用'), findsOneWidget);
    expect(find.text('NewPipe 测试版'), findsOneWidget);
    expect(find.text('应用 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320 小屏搜索结果不溢出', (tester) async {
    SharedPreferences.setMockInitialValues({});
    ApiClient.httpClient = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/apps')) {
        return _ok({
          'list': [_app],
          'total': 1,
          'page': 1,
          'pageSize': 20,
        });
      }
      if (path.endsWith('/search')) {
        return _ok({
          'posts': <dynamic>[],
          'videos': <dynamic>[],
          'users': <dynamic>[],
          'topics': <dynamic>[],
        });
      }
      if (path.endsWith('/feed')) {
        return _ok({'list': <dynamic>[], 'hasMore': false, 'page': 1});
      }
      return _ok({'list': <dynamic>[]});
    });
    addTearDown(() => ApiClient.httpClient = http.Client());

    tester.view.physicalSize = const Size(320 * 2, 700 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildImmersiveTheme(),
        home: const SearchPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    await tester.enterText(find.byType(TextField), 'NewPipe');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));

    expect(find.text('相关应用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
