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

http.Response _json(Object body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  setUpAll(() async {
    await _loadCjk();
  });

  testWidgets('Agent 执行时间线与来源 chips', (tester) async {
    SharedPreferences.setMockInitialValues({
      'community_token': 'tok',
      'af_conv_id': 'c-agent',
    });
    ApiClient.token = 'tok';

    const base = 1795000000.0;
    final client = MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/af/quota')) {
        return _json({
          'ok': true,
          'plan': 'svip',
          'unit': 'token',
          'left': 2964000,
          'gift_left': 2964000,
          'balance': 1260,
          'balance_yuan': 12.6,
        });
      }
      if (p.endsWith('/af/conversations')) {
        return _json({
          'ok': true,
          'list': [
            {
              'id': 'c-agent',
              'title': '苏州天气简报',
              'created': base,
              'updated': base + 30,
            },
          ],
        });
      }
      if (p.endsWith('/af/messages')) {
        return _json({
          'ok': true,
          'list': [
            {
              'id': 'u1',
              'role': 'user',
              'content': '查一下苏州明天天气，做一页简报发我。',
              'created': base,
            },
            {
              'id': 'a1',
              'role': 'assistant',
              'content':
                  '查完了：明天苏州多云，12–19℃，东南风 2 级。简报已经生成并发布。 '
                  '[[AF_SUMMARY]]'
                  '明天苏州多云，12–19℃，东南风 2 级，适合出门。简报已交付。'
                  '[[/AF_SUMMARY]]',
              'reasoning':
                  '先确认用户要的是明天、苏州、一页简报。'
                  '接着并行搜天气源，优先中央气象台和天气网；'
                  '再打开页面核对温度、风力和发布时间，最后生成 HTML 并通过 publish_file 交付。',
              'created': base + 28,
              'ms': 800000,
            },
          ],
          'items': [
            {
              'created': base + 3,
              'payload': {
                'id': 'call_search',
                'name': 'web_search',
                'status': 'ok',
                'args': {'query': '苏州明天天气'},
                'detail': {
                  'count': 4,
                  'results': [
                    {
                      'title': '苏州天气预报',
                      'url':
                          'https://www.weather.com.cn/weather/101190401.shtml',
                      'domain': 'www.weather.com.cn',
                    },
                    {
                      'title': '苏州明日天气',
                      'url': 'https://www.tianqi.com/suzhou/tomorrow/',
                      'domain': 'www.tianqi.com',
                    },
                  ],
                },
              },
            },
            {
              'created': base + 9,
              'payload': {
                'id': 'call_fetch',
                'name': 'fetch_url',
                'status': 'ok',
                'args': {
                  'url': 'https://www.weather.com.cn/weather/101190401.shtml',
                },
                'detail': {
                  'title': '苏州天气预报',
                  'domain': 'www.weather.com.cn',
                  'url': 'https://www.weather.com.cn/weather/101190401.shtml',
                },
              },
            },
            {
              'created': base + 16,
              'payload': {
                'id': 'call_bash',
                'name': 'bash',
                'status': 'ok',
                'args': {'cmd': 'python3 make_brief.py'},
                'detail': {'code': 0, 'ms': 1840},
              },
            },
            {
              'created': base + 21,
              'payload': {
                'id': 'call_publish',
                'name': 'publish_file',
                'status': 'ok',
                'args': {'path': '/work/苏州天气简报.html'},
                'detail': {
                  'file': '苏州天气简报.html',
                  'size': 24576,
                  'kind': 'html',
                  'url': 'https://example.com/brief.html',
                },
              },
            },
          ],
        });
      }
      return _json({'ok': true});
    });

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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

    // ignore: avoid_print
    print(
      'TEXTS: ' +
          tester
              .widgetList<Text>(find.byType(Text))
              .map((e) => e.data ?? '')
              .where((e) => e.isNotEmpty)
              .join(' | '),
    );
    // 豆包式任务过程：阶段标题 + 人话说明，不出现卡片式进度计数。
    expect(find.text('检索资料'), findsOneWidget);
    expect(find.text('读取资料'), findsOneWidget);
    expect(find.text('执行命令'), findsOneWidget);
    expect(find.text('交付成品'), findsOneWidget);
    expect(find.textContaining('「苏州明天天气」搜索完成'), findsOneWidget);
    expect(find.text('执行过程'), findsNothing);
    expect(find.text('4/4'), findsNothing);
    expect(find.textContaining('来源'), findsOneWidget);
    expect(find.text('www.weather.com.cn'), findsWidgets);
    // 思考默认折叠：只保留一行入口，不把 reasoning 铺在正文里。
    expect(find.text('思考过程'), findsOneWidget);
    expect(find.textContaining('先确认用户要的是明天'), findsNothing);
    await tester.ensureVisible(find.text('思考过程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();
    expect(find.textContaining('先确认用户要的是明天'), findsOneWidget);
    await tester.ensureVisible(find.text('思考过程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();
    expect(find.textContaining('先确认用户要的是明天'), findsNothing);

    await expectLater(
      find.byType(AfWorkbenchPage),
      matchesGoldenFile('golden/af_agent_trace_390.png'),
    );

    // 再看一眼卡片顶部：处理时长 + 虚线 + 阶段列表开头
    await tester.ensureVisible(find.text('已处理 13 分 20 秒'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(AfWorkbenchPage),
      matchesGoldenFile('golden/af_agent_card_top_390.png'),
    );
  });
}
