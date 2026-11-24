import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/pages/home/af_workbench_page.dart';

Future<void> _loadCjk() async {
  const path = '/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf';
  final f = File(path);
  if (f.existsSync()) {
    final bytes = await f.readAsBytes();
    final loader = FontLoader('CJK')
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }
  // 工坊页内置字体：真机由 pubspec 注册，测试里手动注册才能渲染中文
  final icons = File(
    '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    final ib = await icons.readAsBytes();
    final il = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.view(ib.buffer)));
    await il.load();
  }
  final f2 = File('assets/fonts/NotoSansSC-Regular.otf');
  if (f2.existsSync()) {
    final b2 = await f2.readAsBytes();
    final l2 = FontLoader('NotoSansSC')
      ..addFont(Future.value(ByteData.view(b2.buffer)));
    await l2.load();
  }
}

void main() {
  setUpAll(() async {
    await _loadCjk();
  });

  testWidgets('会话抽屉与切换渲染', (tester) async {
    SharedPreferences.setMockInitialValues({
      'community_token': 'tok',
      'af_conv_id': 'c1',
    });
    ApiClient.token = 'tok';

    final client = MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/af/quota')) {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'ok': true,
              'plan': 'free',
              'unit': 'token',
              'left': 10643,
              'gift_left': 10643,
              'balance': 1200,
              'balance_yuan': 12.0,
              'w5h': 10643,
              'limit_w5h': 20000,
              'blocked_by': '',
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (p.endsWith('/af/conversations')) {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'ok': true,
              'list': [
                {
                  'id': 'c2',
                  'title': '做一个官网',
                  'created': 1794850000.0,
                  'updated': 1794850000.0,
                },
                {
                  'id': 'c1',
                  'title': '主对话',
                  'created': 1794800000.0,
                  'updated': 1794800000.0,
                },
              ],
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (p.endsWith('/af/messages')) {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'ok': true,
              'list': [
                {'role': 'user', 'content': '帮我整理这个文件'},
                {'role': 'assistant', 'content': '整理好了，你看看。'},
                {'role': 'user', 'content': '给我一段 Python 代码'},
                {
                  'role': 'assistant',
                  'content': '## 一个例子\n用 `requests` 抓页面，**注意超时**：\n\n```python\nimport requests\n\nresp = requests.get(\"https://example.com\", timeout=5)\nprint(resp.status_code)\n```\n\n- 记得设 timeout\n- 出错要重试\n\n详细说明见 [官方文档](https://docs.python-requests.org)。',
                },
              ],
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{}', 404);
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'CJK'),
        home: AfWorkbenchPage(client: client),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byIcon(Icons.segment_rounded));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('聊天模式'), findsOneWidget);
    expect(find.text('快速'), findsOneWidget);
    expect(find.text('会话'), findsOneWidget);
    expect(find.text('新建对话'), findsOneWidget);
    expect(find.text('做一个官网'), findsOneWidget);
    expect(find.text('主对话'), findsWidgets);
    expect(find.text('一个例子'), findsOneWidget);
    expect(find.text('python'), findsOneWidget);
    expect(find.text('复制'), findsWidgets);

    await expectLater(
      find.byType(AfWorkbenchPage),
      matchesGoldenFile('golden/af_conv_drawer.png'),
    );

    // 关抽屉，开模式弹窗
    await tester.tapAt(const Offset(600, 300));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('聊天模式'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('小萤怎么帮你'), findsOneWidget);
    expect(find.text('Agent 模式'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('golden/af_mode_sheet.png'),
    );
  });

  testWidgets('附件面板渲染', (tester) async {
    SharedPreferences.setMockInitialValues({
      'community_token': 'tok',
      'af_conv_id': 'c1',
    });
    ApiClient.token = 'tok';

    final client = MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/af/quota')) {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'ok': true,
              'plan': 'svip',
              'unit': 'token',
              'left': 3000000,
              'gift_left': 3000000,
              'balance': 1200,
              'balance_yuan': 12.0,
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response.bytes(
        utf8.encode(jsonEncode({'ok': true, 'list': <dynamic>[]})),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'CJK'),
        home: AfWorkbenchPage(client: client),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(find.textContaining('SVIP'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pump(const Duration(milliseconds: 320));

    expect(find.text('添加到对话'), findsOneWidget);
    expect(find.text('相册'), findsOneWidget);
    expect(find.text('拍照'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
    expect(find.text('记忆'), findsOneWidget);
    expect(find.text('新对话'), findsOneWidget);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('golden/af_attach_sheet.png'),
    );
  });

  testWidgets('文件产物卡片渲染', (tester) async {
    SharedPreferences.setMockInitialValues({
      'community_token': 'tok',
      'af_conv_id': 'c1',
    });
    ApiClient.token = 'tok';

    final client = MockClient((req) async {
      final p = req.url.path;
      final hdr = {'content-type': 'application/json; charset=utf-8'};
      http.Response bytes(Map<String, dynamic> o) =>
          http.Response.bytes(utf8.encode(jsonEncode(o)), 200, headers: hdr);
      if (p.endsWith('/af/quota')) {
        return bytes({
          'ok': true,
          'plan': 'svip',
          'left': 3000000,
          'gift_left': 3000000,
          'balance': 0,
          'balance_yuan': 0.0,
        });
      }
      if (p.endsWith('/af/conversations')) {
        return bytes({
          'ok': true,
          'list': [
            {
              'id': 'c1',
              'title': '主对话',
              'created': 1794800000.0,
              'updated': 1794800000.0,
            },
          ],
        });
      }
      if (p.endsWith('/af/messages')) {
        return bytes({'ok': true, 'list': <dynamic>[]});
      }
      if (p.endsWith('/af/chat')) {
        final body = [
          'event: meta',
          'data: {"conv_id":"c1"}',
          '',
          'event: delta',
          'data: {"t":"PPT 做好了，点卡片上的按钮下载或放大看。"}',
          '',
          'event: tool',
          'data: {"name":"publish_file","status":"ok","detail":{"cmd":"publish /mnt/user-data/outputs/官网方案.pptx","url":"https://www.dbmt999.asia/community/api/media/af/u/exports/x.pptx","file":"流萤社区-官网方案.pptx","size":30233,"kind":"ppt","office":"https://view.officeapps.live.com/op/view.aspx?src=x"}}',
          '',
          'event: usage',
          'data: {"tokens_in":100,"tokens_out":50,"gift":150,"fen":0,"mode":"chat"}',
          '',
          'event: done',
          'data: {"ok":true}',
          '',
          '',
        ].join('\n');
        return http.Response.bytes(
          utf8.encode(body),
          200,
          headers: {'content-type': 'text/event-stream; charset=utf-8'},
        );
      }
      return bytes({'ok': true, 'list': <dynamic>[]});
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'CJK'),
        home: AfWorkbenchPage(client: client),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byType(TextField), '帮我做个官网 PPT');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump(const Duration(milliseconds: 300));

    // 顶栏右侧必须有可点的返回/关闭键
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);

    final ex = tester.takeException();
    // ignore: avoid_print
    print('EXCEPTION: $ex');
    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      final d = t.data ?? '';
      if (d.contains('出错') || d.contains('PPT') || d.contains('按')) {
        // ignore: avoid_print
        print('TEXT: $d');
      }
    }
    expect(find.text('帮我做个官网 PPT'), findsOneWidget);
    expect(find.text('PPT 做好了，点卡片上的按钮下载或放大看。'), findsOneWidget);
    expect(find.text('流萤社区-官网方案.pptx'), findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsWidgets);
    expect(find.byIcon(Icons.open_in_full_rounded), findsWidgets);
    expect(find.byIcon(Icons.slideshow_rounded), findsOneWidget);

    await expectLater(
      find.byType(AfWorkbenchPage),
      matchesGoldenFile('golden/af_file_card.png'),
    );
  });
}
