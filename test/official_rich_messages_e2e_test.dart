/// 官方通知富文本端到端：真实 Python 后端 + 真实 SQLite + 真实 HTTP + 真实页面。
///
/// 覆盖：
/// - 管理端提交结构化富文本 → 后端白名单规范化 → 用户 API 返回 rich；
/// - 官方通知聊天气泡按标题 / 加粗 / 主色 / 引用 / 列表 / 链接 / 图片渲染；
/// - 老纯文本通知仍按文字气泡展示。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'path_provider_mock.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/features/message/data/message_repository.dart';
import 'package:community_app/pages/message/official_messages_page.dart';

const _me = 'e2e_me';
const _tokMe = 'e2e-token-me';
final _root = Directory.current.path;
final _fixture = '$_root/community/tests/message_e2e_fixture.py';

class _RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context);
}

Process? _server;
String? _dbPath;
int _portSeq = 8811;

Future<void> _startServer() async {
  final port = _portSeq++;
  _dbPath = '/tmp/official_rich_${DateTime.now().microsecondsSinceEpoch}.db';
  _server = await Process.start('python3', [
    _fixture,
    '--db',
    _dbPath!,
    '--port',
    '$port',
  ], workingDirectory: _root);
  final ready = Completer<void>();
  final err = StringBuffer();
  _server!.stderr.transform(utf8.decoder).listen(err.write);
  _server!.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        if (line.startsWith('READY')) {
          if (!ready.isCompleted) ready.complete();
        } else if (line.startsWith('SERVER_FAILED') ||
            line.startsWith('SERVER_TIMEOUT')) {
          if (!ready.isCompleted) ready.completeError(StateError(line));
        }
      });
  await ready.future.timeout(const Duration(seconds: 20));
  ApiClient.baseOverride = 'http://127.0.0.1:$port/community/api';
  ApiClient.token = _tokMe;
  ApiClient.userId = _me;
}

Future<void> _stopServer() async {
  ApiClient.baseOverride = null;
  ApiClient.token = null;
  ApiClient.userId = null;
  final p = _server;
  _server = null;
  if (p != null) {
    p.kill(ProcessSignal.sigterm);
    await p.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        p.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
  final db = _dbPath;
  _dbPath = null;
  if (db != null) {
    for (final suffix in ['', '-wal', '-shm']) {
      try {
        File(db + suffix).deleteSync();
      } catch (_) {}
    }
  }
}

Future<T> _withRealHttp<T>(Future<T> Function() body) {
  final overrides = _RealHttpOverrides();
  return HttpOverrides.runZoned(
    body,
    createHttpClient: (context) => overrides.createHttpClient(context),
  );
}

Future<void> _settle(WidgetTester tester, {int ms = 1200}) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _pump(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(780, 1688);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildImmersiveTheme(),
      home: page,
    ),
  );
  await _settle(tester, ms: 1600);
}

Map<String, dynamic> _richDoc() => {
  'v': 1,
  'blocks': [
    {
      'type': 'heading',
      'level': 2,
      'spans': [
        {'text': '版本更新', 'bold': true, 'color': 'accent'},
      ],
    },
    {
      'type': 'paragraph',
      'spans': [
        {'text': '今晚 '},
        {'text': '23:00', 'bold': true},
        {'text': ' 开始维护，详情见 '},
        {'text': '查看公告', 'url': 'https://www.dbmt999.asia/notice'},
      ],
    },
    {
      'type': 'bullet',
      'spans': [
        {'text': '提前保存草稿', 'color': 'warning'},
      ],
    },
    {
      'type': 'quote',
      'spans': [
        {'text': '预计 30 分钟', 'italic': true, 'color': 'muted'},
      ],
    },
    {'type': 'image', 'url': 'http://127.0.0.1:1/poster.png', 'alt': '维护海报'},
    {'type': 'divider'},
  ],
};

Future<http.Response> _sendRich(http.Client c) => c.post(
  Uri.parse('${ApiClient.baseUrl}/admin/official'),
  headers: {
    'X-Community-Admin-Token': 'e2e-admin-token',
    'Content-Type': 'application/json',
  },
  body: jsonEncode({
    'receiverUserId': _me,
    'content': '版本更新：今晚 23:00 开始维护',
    'rich': _richDoc(),
  }),
);

void main() {
  mockPathProvider();
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    HttpOverrides.global = _RealHttpOverrides();
    SharedPreferences.setMockInitialValues({});
    await _startServer();
  });

  tearDown(() async {
    await _stopServer();
    ApiClient.httpClient = http.Client();
  });

  testWidgets('官方通知：管理端富文本 → API → 聊天气泡真实渲染', (tester) async {
    await _withRealHttp(() async {
      ApiClient.httpClient = http.Client();
      final c = http.Client();
      final sent = await tester.runAsync(() => _sendRich(c));
      expect(sent!.statusCode, 200, reason: sent.body);

      // 先验证后端契约：用户 API 返回 contentType=rich + 可渲染 rich 文档。
      final api = await tester.runAsync(
        () => c.get(
          Uri.parse('${ApiClient.baseUrl}/official-messages?after=0'),
          headers: {'Authorization': 'Bearer $_tokMe'},
        ),
      );
      expect(api!.statusCode, 200, reason: api.body);
      final data = jsonDecode(api.body) as Map<String, dynamic>;
      final list = (data['list'] as List).cast<Map<String, dynamic>>();
      expect(list.length, greaterThanOrEqualTo(3));
      final item = list.lastWhere((e) => e['contentType'] == 'rich');
      expect(item['plainText'], contains('版本更新'));
      final rich = item['rich'] as Map<String, dynamic>;
      expect((rich['blocks'] as List).length, 6);

      // 预热一次真实 HTTP 连接（首个请求可能因测试 HTTP 栈初始化较慢），
      // 页面自身的 _load 必须独立完成加载，不依赖测试注入数据。
      await tester.runAsync(
        () => MessageRepository.instance.officialMessages(),
      );
      await _pump(tester, const OfficialMessagesPage());
      await _settle(tester, ms: 1000);

      final bubble = find.byKey(ValueKey('official-bubble-${item['id']}'));
      expect(bubble, findsOneWidget);
      expect(find.text('版本更新', findRichText: true), findsOneWidget);
      expect(find.text('提前保存草稿', findRichText: true), findsOneWidget);
      expect(find.text('预计 30 分钟', findRichText: true), findsOneWidget);
      expect(
        find.byKey(ValueKey('official-rich-image-${item['id']}-4')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('official-rich-line-${item['id']}-1')),
        findsOneWidget,
      );

      // 加粗 + 主色 + 链接 recognizer 真的进入了 RichText span。
      final titleText = tester.widget<Text>(
        find.byKey(ValueKey('official-rich-line-${item['id']}-0')),
      );
      final titleSpan = titleText.textSpan!;
      expect(titleSpan.toPlainText(), '版本更新');
      expect(
        (titleSpan as TextSpan).children!.any(
          (s) => s.style?.fontWeight == FontWeight.w700,
        ),
        isTrue,
      );
      expect(
        (titleSpan).children!.any(
          (s) => s.style?.color == const Color(AppColors.accent),
        ),
        isTrue,
      );

      final bodyText = tester.widget<Text>(
        find.byKey(ValueKey('official-rich-line-${item['id']}-1')),
      );
      final bodySpan = bodyText.textSpan! as TextSpan;
      expect(
        bodySpan.children!.any(
          (s) =>
              s is TextSpan &&
              s.text == '查看公告' &&
              s.recognizer != null &&
              s.style?.decoration == TextDecoration.underline,
        ),
        isTrue,
      );

      // 老纯文本通知仍走 fallback 气泡，不因富文本改造而白屏。
      final old = await tester.runAsync(
        () => c.post(
          Uri.parse('${ApiClient.baseUrl}/admin/official'),
          headers: {
            'X-Community-Admin-Token': 'e2e-admin-token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'receiverUserId': _me, 'content': '普通文本通知'}),
        ),
      );
      expect(old!.statusCode, 200, reason: old.body);
      await _pump(
        tester,
        const OfficialMessagesPage(key: ValueKey('official-second-load')),
      );
      await _settle(tester, ms: 1000);
      expect(find.text('普通文本通知'), findsOneWidget);
      // 让页面里的 markOfficialRead（真实 POST）走完；再关闭页面 HTTP 客户端，
      // 释放 keep-alive 连接，避免测试结束时残留超时/空闲计时器。
      await _settle(tester, ms: 2000);
      ApiClient.httpClient.close();
      await tester.pump(const Duration(seconds: 21));
      await tester.pump(const Duration(seconds: 1));
      c.close();
    });
  });
}
