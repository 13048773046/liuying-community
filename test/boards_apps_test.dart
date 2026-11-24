/// 板块页应用板块：真实接口结构下，应用横滑要出现在版块首页。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/pages/boards/boards_page.dart';

http.Response _ok(Map<String, dynamic> body) => http.Response(
  jsonEncode({'ok': true, ...body}),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

final Map<String, dynamic> _app = {
  'id': 'app_media_1',
  'name': '测试应用甲',
  'icon': '',
  'platform': 'android',
  'packageType': 'apk',
  'packageName': 'com.test.media',
  'version': '1.0.0',
  'category': '影音',
  'subCategory': '视频',
  'categoryId': 'appcat_media',
  'description': '用于验证板块页应用横滑的测试应用。',
  'downloadCount': 12,
  'rating': 4.5,
  'ratingCount': 2,
  'featured': true,
};

void main() {
  testWidgets('390 宽板块页出现频道矩阵与应用入口', (tester) async {
    ApiClient.httpClient = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/boards')) {
        return _ok({
          'list': [
            {
              'id': 'b_digital',
              'name': '数码',
              'icon': '💻',
              'color': '#4CD9A5',
              'post_count': 3,
              'children': <dynamic>[],
            },
          ],
        });
      }
      if (path.endsWith('/apps/categories')) {
        return _ok({
          'list': [
            {
              'id': 'appcat_media',
              'name': '影音',
              'slug': 'media',
              'parentId': '',
              'children': <dynamic>[],
            },
          ],
        });
      }
      if (path.endsWith('/apps')) {
        return _ok({
          'list': [_app],
          'total': 1,
          'page': 1,
          'pageSize': 20,
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
        home: const BoardsPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.text('版块'), findsWidgets);
    expect(find.text('数码'), findsWidgets);
    expect(find.text('应用橱窗'), findsOneWidget);
    expect(find.text('流萤航线'), findsOneWidget);
    expect(find.text('1 款社区应用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320 小屏板块页不溢出', (tester) async {
    ApiClient.httpClient = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/boards')) {
        return _ok({'list': <dynamic>[]});
      }
      if (path.endsWith('/apps/categories')) {
        return _ok({
          'list': [
            {
              'id': 'appcat_media',
              'name': '影音',
              'slug': 'media',
              'parentId': '',
              'children': <dynamic>[],
            },
          ],
        });
      }
      if (path.endsWith('/apps')) {
        return _ok({
          'list': [_app],
          'total': 1,
          'page': 1,
          'pageSize': 20,
        });
      }
      return _ok({});
    });
    addTearDown(() => ApiClient.httpClient = http.Client());

    tester.view.physicalSize = const Size(320 * 2, 700 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildImmersiveTheme(),
        home: const BoardsPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.text('版块'), findsWidgets);
    expect(find.text('应用橱窗'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
