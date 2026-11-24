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
import 'package:community_app/pages/home/af_billing_page.dart';
import 'package:community_app/pages/home/af_bills_page.dart';
import 'package:community_app/pages/home/af_providers.dart';

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
  // 工坊页内置字体（真机由 pubspec 注册，测试里手动注册才能看到中文）
  await _loadFont('NotoSansSC', 'assets/fonts/NotoSansSC-Regular.otf');
  await _loadFont('CJK', '/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf');
  await _loadFont('MaterialIcons',
      '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  await _loadFont('monospace',
      '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf');
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

MockClient _workbenchClient() => MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/af/quota')) {
        return _json({
          'ok': true,
          'plan': 'svip',
          'unit': 'token',
          'left': 2964000,
          'gift_left': 2964000,
          'balance': 1200,
          'balance_yuan': 12.6,
          'limit_w5h': 3000000,
        });
      }
      if (p.endsWith('/af/conversations')) {
        return _json({
          'ok': true,
          'list': [
            {'id': 'c1', 'title': '主对话', 'created': 1794850000.0, 'updated': 1794850000.0},
            {'id': 'c2', 'title': '官网首页改版', 'created': 1794800000.0, 'updated': 1794800000.0},
            {'id': 'c3', 'title': '活动页文案打磨', 'created': 1794700000.0, 'updated': 1794700000.0},
          ],
        });
      }
      if (p.endsWith('/af/messages')) {
        return _json({
          'ok': true,
          'list': [
            {'role': 'user', 'content': '帮我把这版方案做成官网首页，风格跟前面那版一致，别太花。', 'created': 1794850001.0},
            {
              'role': 'assistant',
              'content': '做好了，三个页面都按同一套色板和字级来，主视觉留白比上一版多。\n\n- 首页\n- 产品页\n- 关于页',
              'created': 1794850002.0,
            },
            {
              'role': 'tool',
              'name': 'publish_file',
              'status': 'ok',
              'detail': {
                'cmd': 'publish 官网方案.html',
                'url': 'https://www.dbmt999.asia/community/api/media/af/u/exports/x.html',
                'file': '流萤社区-官网方案-首页.html',
                'size': 86016,
                'kind': 'html',
                'preview': 'https://www.dbmt999.asia/community/api/media/af/u/exports/x.html',
              },
            },
            {'role': 'user', 'content': '配色再压一点，青别那么跳，然后给我一个移动端的版本。', 'created': 1794850200.0},
            {'role': 'assistant', 'content': '压了一档，主色降到 #3AC9F5，描边统一成 7% 白，圆角收到 13–16。', 'created': 1794850201.0},
          ],
          'items': [
            {
              'created': 1794850100.0,
              'payload': {
                'name': 'publish_file',
                'status': 'ok',
                'detail': {
                  'cmd': 'publish 官网方案.html',
                  'url': 'https://www.dbmt999.asia/community/api/media/af/u/exports/x.html',
                  'file': '流萤社区-官网方案-首页.html',
                  'size': 86016,
                  'kind': 'html',
                  'preview': 'https://www.dbmt999.asia/community/api/media/af/u/exports/x.html',
                },
              },
            },
          ],
        });
      }
      return _json({'ok': true, 'list': <dynamic>[]});
    });

MockClient _billingClient() => MockClient((req) async {
      if (req.url.path.endsWith('/af/quota')) {
        return _json({
          'ok': true,
          'plan': 'svip',
          'left': 2964000,
          'gift_left': 2964000,
          'balance': 1200,
          'balance_yuan': 12.6,
          'limit_w5h': 3000000,
        });
      }
      return _json({'ok': true, 'list': <dynamic>[]});
    });

MockClient _billsClient() => MockClient((req) async {
      return _json({
        'ok': true,
        'list': [
          {
            'kind': 'chat',
            'model': 'deepseek-flash',
            'gift': 19000,
            'fen': 0,
            'tokens_in': 1240,
            'tokens_out': 3180,
            'created': 1763350000.0,
          },
          {
            'kind': 'chat',
            'model': 'p:0974:deepseek-flash',
            'gift': 0,
            'fen': 0,
            'tokens_in': 980,
            'tokens_out': 2400,
            'created': 1763348000.0,
          },
          {
            'kind': 'chat',
            'model': 'deepseek-v4-pro',
            'gift': 14000,
            'fen': 0,
            'tokens_in': 3100,
            'tokens_out': 6900,
            'created': 1763310000.0,
          },
          {
            'kind': 'recharge',
            'fen': 1000,
            'gift': 3000000,
            'note': 'SVIP 月度赠送',
            'created': 1763280000.0,
          },
        ],
      });
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

  Future<void> boot(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(),
      home: home,
    ));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('Agent 主界面新视觉', (tester) async {
    await boot(tester, AfWorkbenchPage(client: _workbenchClient()));

    expect(find.text('小萤 Agent'), findsWidgets);
    expect(find.text('主对话'), findsWidgets);
    // 顶栏：会话列表 / 账单 / 返回(×)
    expect(find.byIcon(Icons.segment_rounded), findsOneWidget);
    expect(find.byIcon(Icons.account_balance_wallet_outlined), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(find.text('聊天模式'), findsOneWidget);
    expect(find.text('快速'), findsOneWidget);

    await expectLater(
      find.byType(AfWorkbenchPage),
      matchesGoldenFile('golden/af_v22_workbench.png'),
    );
  });

  testWidgets('Agent 模式态新视觉', (tester) async {
    await boot(tester, AfWorkbenchPage(client: _workbenchClient()));

    await tester.tap(find.text('聊天模式').first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('小萤怎么帮你'), findsOneWidget);

    await tester.tap(find.text('Agent 模式'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Agent 模式'), findsWidgets);
    expect(find.textContaining('云沙箱'), findsWidgets);

    await expectLater(
      find.byType(AfWorkbenchPage),
      matchesGoldenFile('golden/af_v22_work.png'),
    );
  });

  testWidgets('会话抽屉新视觉', (tester) async {
    await boot(tester, AfWorkbenchPage(client: _workbenchClient()));
    await tester.tap(find.byIcon(Icons.segment_rounded));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('会话'), findsOneWidget);
    expect(find.text('新建对话'), findsOneWidget);
    expect(find.text('官网首页改版'), findsOneWidget);
    expect(find.text('记忆与偏好'), findsOneWidget);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('golden/af_v22_drawer.png'),
    );
  });

  testWidgets('额度与账单页新视觉', (tester) async {
    await boot(tester, AfBillingPage(client: _billingClient()));

    expect(find.text('额度与账单'), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(find.text('套餐'), findsOneWidget);
    expect(find.text('SVIP'), findsWidgets);

    await expectLater(
      find.byType(AfBillingPage),
      matchesGoldenFile('golden/af_v22_billing.png'),
    );
  });

  testWidgets('自建 API 编辑表单', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final p = AfProvider(
      id: 'pid1',
      name: '我的 DeepSeek',
      base: 'https://api.deepseek.com/v1',
      keyHint: 'sk-4****cf53',
      models: const [
        AfProviderModel(id: 'm1', model: 'deepseek-chat', enabled: true),
        AfProviderModel(id: 'm2', model: 'deepseek-reasoner', enabled: true),
      ],
    );

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(),
      home: Builder(
        builder: (ctx) => Center(
          child: TextButton(
            onPressed: () => showAfAddProviderSheet(ctx, edit: p),
            child: const Text('打开'),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('打开'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('编辑 API'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('我的 DeepSeek'), findsWidgets);
    expect(find.text('deepseek-chat'), findsWidgets);
    expect(find.text('deepseek-reasoner'), findsWidgets);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('golden/af_v22_edit_api.png'),
    );
  });

  testWidgets('模型选择弹窗带编辑入口', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final p = AfProvider(
      id: 'pid1',
      name: '我的 DeepSeek',
      base: 'https://api.deepseek.com/v1',
      keyHint: 'sk-4****cf53',
      models: const [
        AfProviderModel(id: 'm1', model: 'deepseek-chat', enabled: true),
        AfProviderModel(id: 'm2', model: 'deepseek-reasoner', enabled: true),
      ],
    );

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(),
      home: Scaffold(
        backgroundColor: const Color(0xFF06070A),
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Material(
            color: const Color(0xFF101012),
            child: AfModelPickerSheet(
              current: 'p:pid1:deepseek-chat',
              onPick: (_) {},
              initialProviders: [p],
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('选择模型'), findsOneWidget);
    expect(find.text('我的 DeepSeek'), findsWidgets);
    expect(find.byIcon(Icons.edit_rounded), findsOneWidget);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('golden/af_v22_picker_edit.png'),
    );
  });

  testWidgets('账单明细新视觉', (tester) async {
    await boot(tester, AfBillsPage(client: _billsClient()));

    expect(find.text('账单明细'), findsOneWidget);
    expect(find.text('自有 Key').first, findsOneWidget);
    expect(find.text('不扣费'), findsOneWidget);

    await expectLater(
      find.byType(AfBillsPage),
      matchesGoldenFile('golden/af_v22_bills.png'),
    );
  });
}
