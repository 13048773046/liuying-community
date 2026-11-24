import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
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

Future<void> _loadFonts() async {
  for (final f in [
    ['NotoSansSC', 'assets/fonts/NotoSansSC-Regular.otf'],
    ['MaterialIcons', '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'],
  ]) {
    final file = File(f[1]);
    if (!file.existsSync()) continue;
    final bytes = await file.readAsBytes();
    final loader = FontLoader(f[0])..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await _loadFonts();
  });

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
      return _json({
        'ok': true,
        'list': [
          for (var i = 0; i < 6; i++)
            {
              'id': 'c$i',
              'title': ['做一个精致的 App 官网', '看看', '看看', '开始写代码呀', '我一个精致的网页', '总结'][i],
              'pinned': 0,
              'created': 1794871330.0 + i,
              'updated': 1794871330.0 + i,
            }
        ],
      });
    }
    if (p.endsWith('/af/messages')) {
      return _json({
        'ok': true,
        'list': [
          {'role': 'user', 'content': '帮我做一个网页', 'created': 1794871330.0},
          {
            'role': 'assistant',
            'content': 'Also more This is crafted also enhanced chrome network maybe headless nothing may carefully. Actual parse write Let me Nav colors sounds Hero section',
            'reasoning': 'Also more. This is crafted also enhanced chrome network maybe headless nothing may carefully. Actual parse write. Let me think Nav colors sounds Hero section.',
            'status': 'done',
            'created': 1794871336.8,
          },
        ],
        'items': <dynamic>[],
      });
    }
    return _json({'ok': true, 'list': <dynamic>[]});
  });

  testWidgets('抽屉打开态渲染截图', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: false, fontFamily: 'NotoSansSC', scaffoldBackgroundColor: Colors.white),
      home: AfWorkbenchPage(client: client),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byIcon(Icons.segment_rounded));
    await tester.pumpAndSettle();

    final out = File('test/golden/af_drawer_check.png');
    final bytes = await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byType(RepaintBoundary).first);
      final img = await boundary.toImage(pixelRatio: 1.0);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    });
    out.writeAsBytesSync(bytes!);
  });
}
