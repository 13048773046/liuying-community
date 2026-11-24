/// 发布闭环：编辑器 -> 点发布 -> 页面退出到根 -> 悬浮卡 -> 成功后自动消失。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/design/tokens.dart';
import 'package:community_app/pages/post/post_editor.dart';
import 'package:community_app/pages/post/publish_overlay.dart';

http.Response _ok(Map<String, dynamic> body) => http.Response(
  jsonEncode({'ok': true, ...body}),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

class _Harness extends StatelessWidget {
  const _Harness();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppColors.bg),
      body: Center(
        child: PillButton(
          label: '打开发布页',
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const PostEditorPage())),
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('发布后退出编辑器并显示悬浮进度卡', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    ApiClient.httpClient = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/boards')) {
        return _ok({
          'list': [
            {
              'id': 'b_life',
              'name': '生活分享',
              'icon': '🍀',
              'children': <dynamic>[],
            },
          ],
        });
      }
      if (path.endsWith('/post')) return _ok({});
      return _ok({'list': <dynamic>[], 'hasMore': false});
    });
    addTearDown(() => ApiClient.httpClient = http.Client());

    final base = buildImmersiveTheme();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: base,
        home: const _Harness(),
      ),
    );

    await tester.tap(find.text('打开发布页'));
    await tester.pumpAndSettle();
    expect(find.byType(PostEditorPage), findsOneWidget);

    // 选版块
    await tester.tap(find.text('选择版块'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('生活分享'));
    await tester.pumpAndSettle();

    // 写正文
    await tester.enterText(find.byType(TextField).first, '把今天的光收进口袋');
    await tester.pumpAndSettle();

    // 发布
    await tester.tap(find.widgetWithText(PillButton, '发布'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(PostEditorPage), findsNothing);
    expect(find.byType(PublishHoverCard), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('已发布'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PublishHoverCard), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
