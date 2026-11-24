import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/pages/search/search_page.dart';

import 'path_provider_mock.dart';

http.Response _ok(Map<String, dynamic> body) => http.Response(
  jsonEncode({'ok': true, ...body}),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  setUpAll(() async {
    final cjk = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'));
    await cjk.load();
    final icons = FontLoader('MaterialIcons');
    final iconBytes = await File(
      '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ).readAsBytes();
    icons.addFont(Future.value(ByteData.view(iconBytes.buffer)));
    await icons.load();
  });

  testWidgets('搜索页个性化结果 390x844', (tester) async {
    mockPathProvider();
    SharedPreferences.setMockInitialValues({});
    ApiClient.httpClient = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/search/hot')) {
        return _ok({
          'list': [
            {'q': '猫'},
          ],
        });
      }
      if (path.endsWith('/search/suggest')) {
        return _ok({'topics': <dynamic>[], 'users': <dynamic>[]});
      }
      if (path.endsWith('/apps')) {
        return _ok({
          'list': [
            {
              'id': 'app_search_1',
              'name': '猫窝白噪音',
              'icon': '',
              'platform': 'android',
              'packageType': 'apk',
              'packageName': 'org.miao.quiet',
              'version': '1.0.2',
              'category': '生活',
              'subCategory': '助眠',
              'description': '雨声、炉火和猫呼噜，适合睡前听。',
              'downloadCount': 21,
              'rating': 4.8,
              'ratingCount': 9,
              'reason': '因为你常逛「生活」分类',
            },
          ],
          'total': 1,
          'page': 1,
          'pageSize': 20,
          'personalized': true,
        });
      }
      if (path.endsWith('/search')) {
        return _ok({
          'personalized': true,
          'posts': [
            {
              'id': 'p1',
              'type': 'text',
              'content': '苏州的秋天太适合散步了。沿着河岸走一圈，风里都是桂花味。',
              'images': <dynamic>[],
              'boardId': 'b_life',
              'topic': <dynamic>['苏州秋天'],
              'likeCount': 18,
              'commentCount': 4,
              'shareCount': 2,
              'created': 1763600000,
              'reason': '因为你常看「生活分享」',
              'author': {'id': 'u1', 'name': '山栀', 'avatar': '', 'level': 6},
            },
          ],
          'videos': <dynamic>[],
          'users': [
            {
              'id': 'u2',
              'name': '流小萤',
              'avatar': '',
              'followers': 2,
              'reason': '你常和 TA 互动',
            },
          ],
          'topics': [
            {'name': '猫', 'postCount': 12, 'reason': '相关话题'},
          ],
        });
      }
      if (path.endsWith('/feed')) {
        return _ok({'list': <dynamic>[], 'hasMore': false, 'page': 1});
      }
      return _ok({});
    });
    addTearDown(() => ApiClient.httpClient = http.Client());

    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildImmersiveTheme().copyWith(
            textTheme: buildImmersiveTheme().textTheme.apply(
              fontFamily: 'NotoSansSC',
            ),
          ),
          home: const SearchPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.enterText(find.byType(TextField), '猫');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1200));

    expect(find.text('相关应用'), findsOneWidget);
    expect(find.text('因为你常逛「生活」分类'), findsOneWidget);
    expect(find.text('你常和 TA 互动'), findsOneWidget);
    // 搜索结果不再叠「猜你想看/发现新内容」理由卡。
    expect(find.text('发现新内容'), findsNothing);
    expect(find.text('因为你常看「生活分享」'), findsNothing);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/search_personalized_390.png'),
    );
  });
}
