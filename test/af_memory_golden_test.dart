import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/pages/home/af_memory_page.dart';

Future<void> _loadCjk() async {
  const path = '/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf';
  final f = File(path);
  if (!f.existsSync()) return;
  final bytes = await f.readAsBytes();
  final loader = FontLoader('CJK')
    ..addFont(Future.value(ByteData.view(bytes.buffer)));
  await loader.load();
}

/// 已登录（真实 token）＋真实接口抓下来的数据，验证记忆库渲染
void main() {
  setUpAll(() async {
    await _loadCjk();
  });

  testWidgets('记忆库真实数据渲染', (tester) async {
    // 真实接口返回的 body（抓自 /af/memory）
    // 该样本按真实接口抓在同一次会话的 /tmp，机器重启后可能不存在，缺失则跳过
    final rawFile = File('/tmp/af_memory_live.json');
    if (!rawFile.existsSync()) return;
    final raw = rawFile.readAsStringSync();

    SharedPreferences.setMockInitialValues({'community_token': 'aftest088139a68839c7a7303e'});

    final client = MockClient((req) async {
      if (req.url.path.endsWith('/af/memory')) {
        return http.Response(raw, 200, headers: {'content-type': 'application/json'});
      }
      return http.Response('{}', 404);
    });

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: 'CJK'),
      home: AfMemoryPage(client: client),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('记忆库'), findsOneWidget);
    expect(find.text('小夏常用薄荷绿这个颜色'), findsOneWidget);
    expect(find.text('用户叫小夏，做 iOS 开发'), findsOneWidget);

    await expectLater(
      find.byType(AfMemoryPage),
      matchesGoldenFile('golden/af_memory_live.png'),
    );
  });
}
