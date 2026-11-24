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

Future<void> _loadFont(String name, String path) async {
  final f = File(path);
  if (!f.existsSync()) return;
  final bytes = await f.readAsBytes();
  final loader = FontLoader(name)
    ..addFont(Future.value(ByteData.view(bytes.buffer)));
  await loader.load();
}

http.Response _json(Object o) => http.Response.bytes(
      utf8.encode(jsonEncode(o)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

/// 构造一屏放不下的历史，用来验证「上滑不跟随、回到底部恢复」
MockClient _longHistory() => MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/af/quota')) {
        return _json({'ok': true, 'plan': 'svip', 'left': 2964000, 'limit_w5h': 3000000});
      }
      if (p.endsWith('/af/conversations')) {
        return _json({
          'ok': true,
          'list': [
            {'id': 'c1', 'title': '长对话', 'created': 1794850000.0, 'updated': 1794850000.0},
          ],
        });
      }
      if (p.endsWith('/af/messages')) {
        final rows = <Map<String, dynamic>>[];
        for (var i = 0; i < 12; i++) {
          rows.add({
            'role': 'user',
            'content': '第 ${i + 1} 轮：帮我把这一段再展开说说，多给点细节。',
            'created': 1794850000.0 + i * 2,
          });
          rows.add({
            'role': 'assistant',
            'content': '这是第 ${i + 1} 轮的回答。',
            'created': 1794850001.0 + i * 2,
          });
        }
        return _json({'ok': true, 'list': rows, 'items': <dynamic>[]});
      }
      return _json({'ok': true, 'list': <dynamic>[]});
    });

void main() {
  setUpAll(() async {
    await _loadFont('LAT', '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf');
    await _loadFont('CJK', '/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf');
    await _loadFont('MaterialIcons',
        '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    await _loadFont('monospace', '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf');
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({'community_token': 'tok', 'af_conv_id': 'c1'});
    ApiClient.token = 'tok';
  });

  testWidgets('上滑出现「回到最新」，点击后恢复跟随', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF06070A),
        fontFamily: 'LAT',
        fontFamilyFallback: const ['CJK'],
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
      ),
      home: AfWorkbenchPage(client: _longHistory()),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump(const Duration(milliseconds: 400));
    // 回底动画是在帧末回调里启动的，需要再补两帧才会真正落到底部
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('回到最新'), findsNothing);

    // 上滑看历史：不再贴底，出现「回到最新」
    await tester.drag(find.byType(ListView), const Offset(0, 320));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('回到最新'), findsOneWidget);

    // 点一下回到最新：恢复跟随，按钮消失，最新一条回到视野里
    await tester.tap(find.text('回到最新'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pumpAndSettle();
    expect(find.text('回到最新'), findsNothing);
    expect(find.text('这是第 12 轮的回答。'), findsOneWidget);
  });
}
