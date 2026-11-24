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

Future<void> _loadAll() async {
  await _loadFont('LAT', '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf');
  await _loadFont(
    'CJK',
    '/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf',
  );
  await _loadFont(
    'MaterialIcons',
    '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  await _loadFont(
    'monospace',
    '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
  );
  await _loadFont('NotoSansSC', 'assets/fonts/NotoSansSC-Regular.otf');
}

ThemeData _theme() => ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: const Color(0xFF06070A),
  fontFamily: 'LAT',
  fontFamilyFallback: const ['CJK'],
  splashFactory: NoSplash.splashFactory,
  highlightColor: Colors.transparent,
);

http.Response _json(Object o) => http.Response.bytes(
  utf8.encode(jsonEncode(o)),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

const _longBody =
    '我先把你给的三段素材合成了一版结构，按「首屏主张 → 核心特性 → 使用场景 → 下载」排，'
    '没有沿用上一版那种大段居中的排版，因为手机上读起来太挤。\n\n'
    '首屏只放一句话主张和一张界面截图，下面接三枚特性卡片，分别对应你强调的离线可用、'
    '跨端同步和自定义主题。每一张卡片都控制在两行以内，避免信息过载。\n\n'
    '中间我补了一节真实使用场景：通勤路上听歌、电脑端接着管理歌单、睡前定时关闭。'
    '这节是新增的，原因是光有特性罗列，用户很难对号入座。\n\n'
    '视觉沿用深色底加青色点缀，标题字重拉到 600，正文 13.5，行高 1.75，'
    '按钮只保留一个主按钮，其它全部降级成文字链，避免到处都在抢注意力。\n\n'
    '最后我把页面导出成单个 HTML，图片全部内联，直接发给别人也能打开。';

MockClient _longClient() => MockClient((req) async {
  final p = req.url.path;
  if (p.endsWith('/af/quota')) {
    return _json({
      'ok': true,
      'plan': 'svip',
      'left': 2964000,
      'limit_w5h': 3000000,
    });
  }
  if (p.endsWith('/af/conversations')) {
    return _json({
      'ok': true,
      'list': [
        {
          'id': 'c1',
          'title': '产品介绍页',
          'created': 1794850000.0,
          'updated': 1794850000.0,
        },
      ],
    });
  }
  if (p.endsWith('/af/messages')) {
    return _json({
      'ok': true,
      'list': [
        {'role': 'user', 'content': '帮我写一份产品介绍，并做成一个网页发我。'},
        {
          'role': 'assistant',
          'content':
              '$_longBody\n\n[[AF_SUMMARY]]\n产品介绍页做好了：首屏主张 + 三枚特性卡 + 使用场景 + 下载区，深色底配青色点缀，已发布成单文件网页。\n[[/AF_SUMMARY]]',
          'status': 'done',
        },
      ],
      'items': [
        {
          'created': 1794850100.0,
          'payload': {
            'name': 'publish_file',
            'status': 'ok',
            'detail': {
              'cmd': 'publish 产品介绍.html',
              'url': 'https://www.dbmt999.asia/community/api/media/af/u/exports/p.html',
              'file': '流萤-产品介绍页.html',
              'size': 48640,
              'kind': 'html',
              'preview': 'https://www.dbmt999.asia/community/api/media/af/u/exports/p.html',
            },
          },
        },
      ],
    });
  }
  return _json({'ok': true, 'list': <dynamic>[]});
});

void main() {
  setUpAll(() async {
    await _loadAll();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'community_token': 'tok',
      'af_conv_id': 'c1',
    });
    ApiClient.token = 'tok';
  });

  group('总结块解析', () {
    test('正文与总结分离', () {
      final r = afSplitSummary('正文内容[[AF_SUMMARY]]\n这是总结\n[[/AF_SUMMARY]]');
      expect(r.body, '正文内容');
      expect(r.summary, '这是总结');
    });

    test('标记未闭合（流式中途）也能拆开', () {
      final r = afSplitSummary('正文[[AF_SUMMARY]]\n写了一半的总结');
      expect(r.body, '正文');
      expect(r.summary, '写了一半的总结');
    });

    test('没有标记时原样返回', () {
      final r = afSplitSummary('普通回复');
      expect(r.body, '普通回复');
      expect(r.summary, '');
    });

    test('兜底摘要取第一段结论，跳过列表', () {
      expect(afFallbackSummary('做好了，三个页面都改完。\n\n- 首页\n- 产品页'), '做好了，三个页面都改完。');
      expect(afFallbackSummary('- 首页\n- 产品页\n\n已全部改完并发布。'), '已全部改完并发布。');
      final s = afFallbackSummary('长' * 200);
      expect(s.length, lessThanOrEqualTo(141));
      expect(s.endsWith('…'), isTrue);
    });
  });

  Future<void> boot(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        home: home,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('豆包式长回复直接铺开，产物独立展示', (tester) async {
    await boot(tester, AfWorkbenchPage(client: _longClient()));

    // 不再出现「本次总结」卡或「查看完整回复」折叠入口。
    expect(find.text('本次总结'), findsNothing);
    expect(find.text('查看完整回复'), findsNothing);
    expect(find.textContaining('产品介绍页做好了'), findsOneWidget);
    expect(find.textContaining('我先把你给的三段素材'), findsOneWidget);
    expect(find.text('流萤-产品介绍页.html'), findsOneWidget);
    // 标记本身不外泄
    expect(find.textContaining('[[AF_SUMMARY]]'), findsNothing);

    await expectLater(
      find.byType(AfWorkbenchPage),
      matchesGoldenFile('golden/af_v24_summary.png'),
    );
  });

  testWidgets('重进会话：旧数据时间戳下文件卡原样保留', (tester) async {
    // 线上真实形态：工具卡的 created 早于 AI 消息（旧版本 AI 只在结束时落库）
    final client = MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/af/quota')) {
        return _json({
          'ok': true,
          'plan': 'svip',
          'left': 1000,
          'limit_w5h': 3000000,
        });
      }
      if (p.endsWith('/af/conversations')) {
        return _json({
          'ok': true,
          'list': [
            {
              'id': 'c9',
              'title': 'PPT',
              'created': 1794871330.0,
              'updated': 1794871337.0,
            },
          ],
        });
      }
      if (p.endsWith('/af/messages')) {
        return _json({
          'ok': true,
          'list': [
            {
              'role': 'user',
              'content': '帮我做一个 2 页的 PPT，主题是秋季读书分享。',
              'created': 1794871330.0,
            },
            {
              'role': 'assistant',
              'content': 'PPT 做好了，两页：封面和书目，配色用了秋天的橙。',
              'status': 'done',
              'created': 1794871336.8,
            },
          ],
          'items': [
            {
              'created': 1794871334.9,
              'payload': {
                'name': 'publish_file',
                'status': 'ok',
                'detail': {
                  'cmd': 'publish 秋季读书分享会.pptx',
                  'url': 'https://www.dbmt999.asia/community/api/media/af/u/exports/p.pptx',
                  'file': '秋季读书分享会.pptx',
                  'size': 30517,
                  'kind': 'ppt',
                },
              },
            },
          ],
        });
      }
      return _json({'ok': true, 'list': <dynamic>[]});
    });

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        home: AfWorkbenchPage(client: client),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('秋季读书分享会.pptx'), findsOneWidget);
    expect(find.text('本次总结'), findsNothing);
    expect(find.textContaining('PPT 做好了'), findsOneWidget);
  });

  testWidgets('重进会话：长回复直接完整显示', (tester) async {
    SharedPreferences.setMockInitialValues({
      'community_token': 'tok',
      'af_conv_id': 'c1',
    });
    final client = MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/af/quota')) {
        return _json({
          'ok': true,
          'plan': 'svip',
          'left': 1000,
          'limit_w5h': 3000000,
        });
      }
      if (p.endsWith('/af/conversations')) {
        return _json({
          'ok': true,
          'list': [
            {
              'id': 'c1',
              'title': '重进',
              'created': 1794850000.0,
              'updated': 1794850000.0,
            },
          ],
        });
      }
      if (p.endsWith('/af/messages')) {
        return _json({
          'ok': true,
          'list': [
            {'role': 'user', 'content': '写个介绍', 'created': 1794850000.0},
            {
              'id': 'm9',
              'role': 'assistant',
              'content':
                  '$_longBody\n\n[[AF_SUMMARY]]\n总结一句话。\n[[/AF_SUMMARY]]',
              'status': 'done',
              'created': 1794850001.0,
            },
          ],
        });
      }
      return _json({'ok': true, 'list': <dynamic>[]});
    });

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        home: AfWorkbenchPage(client: client),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.textContaining('我先把你给的三段素材'), findsOneWidget);
    expect(find.textContaining('总结一句话'), findsOneWidget);
    expect(find.textContaining('查看完整回复'), findsNothing);
  });
}
