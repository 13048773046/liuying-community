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

  testWidgets('退出再进：后端还在生成的内容用打字机续播到完成', (tester) async {
    var calls = 0;
    const full = '你好，我刚才没写完，现在接着把这段话说完。';
    final client = MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/af/quota')) {
        return _json({'ok': true, 'plan': 'svip', 'left': 1000, 'limit_w5h': 3000000});
      }
      if (p.endsWith('/af/conversations')) {
        return _json({
          'ok': true,
          'list': [
            {'id': 'c1', 'title': '续播', 'created': 1794850000.0, 'updated': 1794850000.0},
          ],
        });
      }
      if (p.endsWith('/af/messages')) {
        calls++;
        // 第一次（进会话的历史）：后端还在写，只有一半；
        // 之后（续播轮询）：第二次仍是 streaming，第三次标记 done
        final done = calls >= 3;
        return _json({
          'ok': true,
          'list': [
            {'role': 'user', 'content': '接着说', 'created': 1794850001.0},
            {
              'role': 'assistant',
              'content': calls == 1 ? full.substring(0, 8) : full,
              'status': done ? 'done' : 'streaming',
              'created': 1794850002.0,
            },
          ],
          'items': <dynamic>[],
        });
      }
      return _json({'ok': true, 'list': <dynamic>[]});
    });

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
      home: AfWorkbenchPage(client: client),
    ));

    // fake 定时器靠 pump 推进，网络靠 runAsync 真实等待，交替推进
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
    }
    await tester.pump(const Duration(milliseconds: 300));

    expect(calls, greaterThanOrEqualTo(3));
    expect(find.text(full), findsOneWidget);
  });
}
