import 'dart:async';
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

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'community_token': 'tok',
      'af_conv_id': 'slow',
      'af_model': 'deepseek-flash',
    });
  });

  // slow 会话一直处于 streaming；fast 会话已完成
  final client = MockClient((req) async {
    final p = req.url.path;
    final cid = req.url.queryParameters['conv_id'] ?? '';
    if (p.endsWith('/af/quota')) {
      return _json({'ok': true, 'plan': 'svip', 'left': 999, 'limit_w5h': 3000000});
    }
    if (p.endsWith('/af/conversations')) {
      return _json({
        'ok': true,
        'list': [
          {'id': 'slow', 'title': '长任务', 'pinned': 0, 'created': 1.0, 'updated': 2.0},
          {'id': 'fast', 'title': '闲聊', 'pinned': 0, 'created': 1.0, 'updated': 3.0},
        ],
      });
    }
    if (p.endsWith('/af/messages')) {
      if (cid == 'slow') {
        return _json({
          'ok': true,
          'list': [
            {'role': 'user', 'content': '写一份长方案', 'created': 1.0},
            {
              'role': 'assistant',
              'content': '正在写第一部分，内容还在持续增加。',
              'status': 'streaming',
              'id': 'm-slow',
              'created': 2.0,
            }
          ],
          'items': <dynamic>[],
        });
      }
      return _json({
        'ok': true,
        'list': [
          {'role': 'user', 'content': '你好', 'created': 1.0},
          {'role': 'assistant', 'content': '你好呀。', 'status': 'done', 'id': 'm-fast', 'created': 2.0},
        ],
        'items': <dynamic>[],
      });
    }
    return _json({'ok': true});
  });

  testWidgets('切话题不打断旧会话：新会话可发消息，切回来仍在生成', (tester) async {
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: false, scaffoldBackgroundColor: Colors.white),
      home: AfWorkbenchPage(client: client),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump(const Duration(milliseconds: 300));

    // 进入 slow：后端在生成 → 按钮是「中断」
    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);

    // 打开抽屉切到 fast
    await tester.tap(find.byIcon(Icons.segment_rounded));
    for (var i = 0; i < 12 && find.text('闲聊').hitTestable().evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(find.text('闲聊').hitTestable());
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump(const Duration(milliseconds: 300));

    // fast 会话不是生成中：按钮回到「发送」
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
    expect(find.byIcon(Icons.stop_rounded), findsNothing);

    // 切回 slow：任务还在，续播接管，按钮回到「中断」
    await tester.tap(find.byIcon(Icons.segment_rounded));
    for (var i = 0; i < 12 && find.text('长任务').hitTestable().evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(find.text('长任务').hitTestable());
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump(const Duration(milliseconds: 300));
    debugPrint('slow text: ' + find.textContaining('正在写第一部分').evaluate().length.toString());
    debugPrint('stop icons: ' + find.byIcon(Icons.stop_rounded).evaluate().length.toString());
    debugPrint('send icons: ' + find.byIcon(Icons.arrow_upward_rounded).evaluate().length.toString());
    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
  });
}
