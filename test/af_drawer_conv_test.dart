import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:community_app/pages/home/af_workbench_page.dart';

http.Response _json(Object data) => http.Response(
      jsonEncode(data),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, dynamic> _asMap(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'community_token': 'tok',
      'af_conv_id': 'c1',
      'af_model': 'deepseek-flash',
    });
  });

  final client = MockClient((req) async {
    final p = req.url.path;
    if (p.endsWith('/af/quota')) {
      return _json({'ok': true, 'plan': 'svip', 'left': 1000, 'limit_w5h': 3000000});
    }
    if (p.endsWith('/af/conversations')) {
      if (req.method == 'PUT') return _json({'ok': true});
      return _json({
        'ok': true,
        'list': [
          {'id': 'c1', 'title': 'PPT 那轮', 'pinned': 0, 'created': 1794871330.0, 'updated': 1794871337.0},
          {'id': 'c2', 'title': '闲聊', 'pinned': 0, 'created': 1794871400.0, 'updated': 1794871405.0},
        ],
      });
    }
    if (p.endsWith('/af/messages')) {
      return _json({
        'ok': true,
        'list': [
          {'role': 'user', 'content': '帮我做一个 2 页 PPT', 'created': 1794871330.0},
          {'role': 'assistant', 'content': 'PPT 做好了。', 'status': 'done', 'created': 1794871336.8},
        ],
        'items': <dynamic>[],
      });
    }
    return _json({'ok': true, 'list': <dynamic>[]});
  });

  ThemeData theme() => ThemeData(
        useMaterial3: false,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: const ColorScheme.light(primary: Color(0xFF45E0AE)),
      );

  testWidgets('侧滑栏是抽屉柜式：打开时主界面被推到右边，不是覆盖', (tester) async {
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme(),
      home: AfWorkbenchPage(client: client),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byIcon(Icons.segment_rounded));
    await tester.pumpAndSettle();

    // 主界面整体右移 ~318（抽屉宽度），说明是推开而不是盖上去
    final shifted = tester
        .widgetList<Transform>(find.byType(Transform))
        .where((t) => t.transform.getTranslation().x > 300)
        .length;
    expect(shifted, greaterThanOrEqualTo(1));

    // 抽屉内容出现
    expect(find.text('会话'), findsWidgets);
    expect(find.text('闲聊'), findsOneWidget);
  });

  testWidgets('长按会话弹出：修改名称 / 置顶 / 删除', (tester) async {
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme(),
      home: AfWorkbenchPage(client: client),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byIcon(Icons.segment_rounded));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('闲聊'));
    await tester.pumpAndSettle();

    expect(find.text('修改名称'), findsOneWidget);
    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('删除会话'), findsOneWidget);

    // 点置顶：发 PUT 并关闭弹窗
    await tester.tap(find.text('置顶'));
    await tester.pumpAndSettle();
    expect(find.text('删除会话'), findsNothing);
  });
}
