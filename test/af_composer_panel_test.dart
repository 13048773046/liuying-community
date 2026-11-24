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

Future<void> _loadFonts() async {
  for (final entry in {
    'MaterialIcons': '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    'CJK': '/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf',
    'NotoSansSC': 'assets/fonts/NotoSansSC-Regular.otf',
  }.entries) {
    final f = File(entry.value);
    if (!f.existsSync()) continue;
    final bytes = await f.readAsBytes();
    final loader = FontLoader(entry.key)
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }
}

http.Response _json(Object data) => http.Response.bytes(
  utf8.encode(jsonEncode(data)),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  setUpAll(_loadFonts);

  testWidgets('工坊：附件名称、内嵌面板与用户附件卡', (tester) async {
    SharedPreferences.setMockInitialValues({
      'community_token': 'tok',
      'af_conv_id': 'c1',
    });
    ApiClient.token = 'tok';

    final client = MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/af/quota')) {
        return _json({
          'ok': true,
          'plan': 'svip',
          'left': 2000000,
          'limit_w5h': 3000000,
        });
      }
      if (p.endsWith('/af/conversations')) {
        return _json({
          'ok': true,
          'list': [
            {'id': 'c1', 'title': '主对话', 'created': 1.0, 'updated': 2.0},
          ],
        });
      }
      if (p.endsWith('/af/messages')) {
        return _json({
          'ok': true,
          'list': [
            {
              'role': 'user',
              'content':
                  '帮我看看这两份东西\n\n'
                  '[用户发来附件]\n'
                  '- [图片] 截图示例.png（18231B）\n'
                  '  https://example.com/demo.png\n'
                  '- [文件] 周报.docx（12345B）\n'
                  '  https://example.com/demo.docx',
              'created': 1.0,
            },
            {
              'role': 'assistant',
              'content': '收到，图片和文件我都看到了。',
              'status': 'done',
              'id': 'm1',
              'created': 2.0,
            },
          ],
          'items': [],
        });
      }
      return _json({'ok': true});
    });

    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'CJK'),
        home: AfWorkbenchPage(client: client),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('截图示例.png'), findsOneWidget);
    expect(find.text('周报.docx'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('添加到对话'), findsOneWidget);
    expect(find.text('相册'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
    expect(find.text('记忆'), findsOneWidget);

    await expectLater(
      find.byType(AfWorkbenchPage),
      matchesGoldenFile('golden/af_composer_panel.png'),
    );
  });
}
