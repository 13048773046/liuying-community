/// 版块页父级内容流回归：有子版块时默认必须查父版块（含全部子版块），
/// 不能一进页面就锁死在第一个子版块，导致父版块旧帖加载不出来。
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

void main() {
  testWidgets('父版块默认展示全部，切子版块才按子版块过滤', (tester) async {
    final feedBoardIds = <String>[];
    ApiClient.httpClient = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/boards')) {
        return _ok({
          'list': [
            {
              'id': 'b_parent',
              'name': '数码',
              'icon': '💻',
              'color': '#4CD9A5',
              'post_count': 12,
              'children': [
                {
                  'id': 'b_child_a',
                  'name': '手机',
                  'icon': '',
                  'color': '#4CD9A5',
                  'post_count': 7,
                  'children': <dynamic>[],
                },
                {
                  'id': 'b_child_b',
                  'name': '电脑',
                  'icon': '',
                  'color': '#4CD9A5',
                  'post_count': 5,
                  'children': <dynamic>[],
                },
              ],
            },
          ],
        });
      }
      if (path.endsWith('/apps/categories')) {
        return _ok({'list': <dynamic>[]});
      }
      if (path.endsWith('/apps')) {
        return _ok({
          'list': <dynamic>[],
          'total': 0,
          'page': 1,
          'pageSize': 20,
        });
      }
      if (path.endsWith('/feed')) {
        feedBoardIds.add(req.url.queryParameters['board_id'] ?? '');
        return _ok({'list': <dynamic>[], 'hasMore': false, 'page': 1});
      }
      return _ok({});
    });
    addTearDown(() => ApiClient.httpClient = http.Client());

    tester.view.physicalSize = const Size(390 * 2, 1400 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(theme: buildImmersiveTheme(), home: const BoardsPage()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 700));

    expect(feedBoardIds, isNotEmpty);
    expect(feedBoardIds.first, 'b_parent', reason: '默认必须加载父版块全部内容');
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('手机'), findsOneWidget);

    await tester.tap(find.text('手机'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(feedBoardIds.last, 'b_child_a');
    expect(tester.takeException(), isNull);
  });
}
