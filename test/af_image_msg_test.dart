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
      'af_conv_id': 'cimg1',
      'af_model': 'deepseek-flash',
    });
  });

  final client = MockClient((req) async {
    final p = req.url.path;
    if (p.endsWith('/af/quota')) {
      return _json({'ok': true, 'plan': 'svip', 'left': 999, 'limit_w5h': 3000000});
    }
    if (p.endsWith('/af/conversations')) {
      return _json({
        'ok': true,
        'list': [
          {'id': 'cimg1', 'title': '画图', 'pinned': 0, 'created': 1.0, 'updated': 2.0}
        ],
      });
    }
    if (p.endsWith('/af/messages')) {
      return _json({
        'ok': true,
        'list': [
          {'role': 'user', 'content': '画一张海报', 'created': 1.0},
          {
            'role': 'assistant',
            'content': '海报画好了：\n![流萤社区海报](https://example.com/poster.png)\n你看这张行不行。',
            'status': 'done',
            'id': 'm1',
            'created': 2.0,
          },
        ],
        'items': [
          {
            'created': 2.1,
            'payload': {
              'name': 'publish_file',
              'status': 'ok',
              'detail': {
                'url': 'https://example.com/poster.png',
                'file': 'poster.png',
                'size': 20480,
                'kind': 'image',
              },
            },
          }
        ],
      });
    }
    return _json({'ok': true});
  });

  testWidgets('图片消息：正文图片渲染 + 图片卡缩略图', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: false, scaffoldBackgroundColor: Colors.white),
      home: AfWorkbenchPage(client: client),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump(const Duration(milliseconds: 400));

    // 正文里的 ![说明](url) 与图片卡缩略图都渲染成图片组件
    expect(find.byType(Image), findsWidgets);
    // 文件名还在卡片里
    expect(find.text('poster.png'), findsWidgets);
  });
}
