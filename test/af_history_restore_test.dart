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

void main() {
  setUpAll(() async {
    await _loadFont('LAT', '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf');
    await _loadFont(
      'CJK',
      '/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf',
    );
  });

  testWidgets(
    '重进会话：思考文本 + 文件卡都还原',
    skip: true,
    // 历史用例：v25 起长回复折叠成总结卡，该断言与现行为不符；折叠/展开由 af_summary_test 覆盖
    (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        'community_token': 'tok',
        'af_conv_id': 'c1',
        'af_mode': 'work',
        'af_model': 'deepseek-v4-pro',
        'af_effort': 'high',
      });
      ApiClient.token = 'tok';

      final conv = {
        'id': 'c1',
        'title': '做个PPT',
        'model': 'deepseek-v4-pro',
        'effort': 'high',
        'pinned': 0,
        'created': 100.0,
        'updated': 200.0,
      };
      final messages = {
        'ok': true,
        'list': [
          {
            'id': 'm1',
            'role': 'user',
            'content': '帮我做个PPT',
            'reasoning': '',
            'created': 100.0,
          },
          {
            'id': 'm2',
            'role': 'assistant',
            'content': '做好了，点上面链接就能下载。',
            'reasoning': '先想一下页数和配色',
            'created': 200.0,
          },
        ],
        'items': [
          {
            'created': 150.0,
            'payload': {
              'name': 'publish_file',
              'args': {},
              'status': 'ok',
              'detail': {
                'url': 'https://www.dbmt999.asia/community/api/media/af/u1/秋季读书分享会.pptx',
                'file': '秋季读书分享会.pptx',
                'size': 30517,
                'kind': 'ppt',
                'preview': 'https://www.dbmt999.asia/community/api/media/af/u1/秋季读书分享会.pptx',
              },
              'result': 'ok',
            },
          },
        ],
      };

      final client = MockClient((req) async {
        final p = req.url.path;
        Map<String, dynamic> body = {'ok': true};
        if (p.endsWith('/af/quota')) {
          body = {
            'ok': true,
            'plan': 'svip',
            'unit': 'token',
            'left': 1000000,
            'gift_left': 1000000,
            'balance': 0,
            'balance_yuan': 0,
            'month_left': 0,
            'w5h_left': 0,
            'd7_left': 0,
            'limit_month': 0,
            'limit_w5h': 0,
            'limit_d7': 0,
            'cache_hit': 0,
            'cache_miss': 0,
            'blocked_by': '',
            'storage': {'used': 0, 'quota_mb': 1024},
            'auth_mode': 'confirm',
            'need_recharge': false,
          };
        } else if (p.endsWith('/af/conversations')) {
          body = {
            'ok': true,
            'list': [conv],
          };
        } else if (p.endsWith('/af/messages')) {
          body = messages;
        } else if (p.endsWith('/af/files')) {
          body = {'ok': true, 'list': []};
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode(body)),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            scaffoldBackgroundColor: Colors.black,
            fontFamily: 'LAT',
            fontFamilyFallback: const ['CJK'],
            splashFactory: NoSplash.splashFactory,
          ),
          home: AfWorkbenchPage(client: client),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      for (var i = 0; i < 30; i++) {
        if (find.textContaining('做好了').evaluate().isNotEmpty) break;
        await tester.pump(const Duration(milliseconds: 100));
      }
      // 豆包式：思考默认折叠，只留一行入口。
      expect(find.text('思考过程'), findsOneWidget);
      expect(find.textContaining('先想一下页数和配色'), findsNothing);
      await tester.ensureVisible(find.text('思考过程'));
      await tester.pump();
      await tester.tap(find.text('思考过程'));
      await tester.pumpAndSettle();
      expect(find.textContaining('先想一下页数和配色'), findsWidgets);
      // 用户消息与正文还原
      expect(find.textContaining('帮我做个PPT'), findsWidgets);
      expect(find.textContaining('做好了'), findsWidgets);
      // 文件卡还原（文件名 + 体积）
      expect(find.textContaining('秋季读书分享会.pptx'), findsWidgets);
      expect(find.textContaining('29.8 KB'), findsWidgets);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 400));
    },
  );
}
