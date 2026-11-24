/// 消息域所有“列表/聊天页”实时性端到端：
/// 真实 Python 后端 + 真实 SQLite + 真实 HTTP + 真实 WebSocket + 真实页面。
///
/// 覆盖：消息页私信列表、私信独立会话列表、互动通知二级列表、官方通知聊天页。
/// 每个用例都不调用刷新、不点击重进，只让外部账号真实发一条消息/通知。
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
import 'package:community_app/pages/message/dm_chat_page.dart';
import 'package:community_app/pages/message/dm_conversations_page.dart';
import 'package:community_app/pages/message/message_page.dart';
import 'package:community_app/pages/message/notif_list_page.dart';
import 'package:community_app/pages/message/official_messages_page.dart';
import 'package:community_app/services/notify_bus.dart';

const _me = 'e2e_me';
const _peer = 'e2e_peer';
const _other = 'e2e_other';
const _tokMe = 'e2e-token-me';
const _tokPeer = 'e2e-token-peer';
final _root = Directory.current.path;
final _fixture = '$_root/community/tests/message_e2e_fixture.py';
final _convPeer =
    [_me, _peer].reduce((a, b) => a.compareTo(b) <= 0 ? a : b) +
    '_' +
    [_me, _peer].reduce((a, b) => a.compareTo(b) <= 0 ? b : a);
final _convOther =
    [_me, _other].reduce((a, b) => a.compareTo(b) <= 0 ? a : b) +
    '_' +
    [_me, _other].reduce((a, b) => a.compareTo(b) <= 0 ? b : a);

class _RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context);
}

Process? _server;
String? _dbPath;
int _portSeq = 8821;

Future<void> _startServer() async {
  final port = _portSeq++;
  _dbPath = '/tmp/message_views_${DateTime.now().microsecondsSinceEpoch}.db';
  _server = await Process.start('python3', [
    _fixture,
    '--db',
    _dbPath!,
    '--port',
    '$port',
    '--two-convs',
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
  NotifyBus.shared.disconnect();
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

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() condition, {
  int attempts = 14,
}) async {
  for (var i = 0; i < attempts; i++) {
    if (condition()) return;
    await _settle(tester);
  }
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
  await _settle(tester, ms: 1800);
}

Future<void> _connectBus(WidgetTester tester) async {
  await tester.runAsync(() async {
    NotifyBus.shared.connect(_tokMe);
    await Future<void>.delayed(const Duration(milliseconds: 700));
  });
}

Future<void> _sendDm(
  http.Client c, {
  required String token,
  required String content,
}) async {
  final r = await c.post(
    Uri.parse('${ApiClient.baseUrl}/dm/send'),
    headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({'peer': _me, 'content': content}),
  );
  expect(r.statusCode, 200, reason: r.body);
}

double _dy(WidgetTester tester, String convId) =>
    tester.getTopLeft(find.byKey(ValueKey('dm-conv-$convId'))).dy;

/// 关闭页面在用 HTTP 客户端并推进 fake clock，释放缓存/keep-alive 计时器。
Future<void> _drainTimers(WidgetTester tester) async {
  ApiClient.httpClient.close();
  await tester.pump(const Duration(seconds: 21));
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  mockPathProvider();
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    HttpOverrides.global = _RealHttpOverrides();
    SharedPreferences.setMockInitialValues({});
    NotifyBus.enabled = true;
    NotifyBus.shared.clearUnread();
    NotifyBus.shared.clearDmUnread();
    NotifyBus.shared.clearOfficialUnread();
    await _startServer();
  });

  tearDown(() async {
    await _stopServer();
    ApiClient.httpClient = http.Client();
  });

  testWidgets('消息页：新私信到达后会话本地置顶、预览和未读角标自动更新', (tester) async {
    await _withRealHttp(() async {
      ApiClient.httpClient = http.Client();
      await _pump(tester, const MessagePage());
      await _waitUntil(
        tester,
        () => find.text('3 条未读私信').evaluate().isNotEmpty,
      );

      expect(find.byKey(ValueKey('dm-conv-$_convPeer')), findsOneWidget);
      expect(find.byKey(ValueKey('dm-conv-$_convOther')), findsOneWidget);
      // 初始：另一个会话时间更新，排在私信会话前面。
      expect(_dy(tester, _convOther), lessThan(_dy(tester, _convPeer)));

      await _connectBus(tester);
      final c = http.Client();
      await tester.runAsync(
        () => _sendDm(c, token: _tokPeer, content: '实时列表更新：歌单好了'),
      );
      await _waitUntil(
        tester,
        () => find.text('实时列表更新：歌单好了').evaluate().isNotEmpty,
      );
      // 零点击、零刷新：会话被顶到第一条，预览变成新消息，角标 3→4。
      expect(_dy(tester, _convPeer), lessThan(_dy(tester, _convOther)));
      expect(
        find.descendant(
          of: find.byKey(ValueKey('dm-conv-$_convPeer')),
          matching: find.text('4'),
        ),
        findsOneWidget,
      );
      expect(find.text('4 条未读私信'), findsOneWidget);
      await _drainTimers(tester);
      c.close();
    });
  });

  testWidgets('私信独立列表：新私信到达后同样本地置顶并更新预览/未读', (tester) async {
    await _withRealHttp(() async {
      ApiClient.httpClient = http.Client();
      await _pump(tester, const DmConversationsPage());
      await _waitUntil(
        tester,
        () => find.byKey(ValueKey('dm-conv-$_convPeer')).evaluate().isNotEmpty,
      );
      expect(find.byKey(ValueKey('dm-conv-$_convPeer')), findsOneWidget);
      expect(find.byKey(ValueKey('dm-conv-$_convOther')), findsOneWidget);
      expect(_dy(tester, _convOther), lessThan(_dy(tester, _convPeer)));

      await _connectBus(tester);
      final c = http.Client();
      await tester.runAsync(
        () => _sendDm(c, token: _tokPeer, content: '独立列表实时更新：到了'),
      );
      await _waitUntil(
        tester,
        () => find.text('独立列表实时更新：到了').evaluate().isNotEmpty,
      );
      expect(_dy(tester, _convPeer), lessThan(_dy(tester, _convOther)));
      expect(
        find.descendant(
          of: find.byKey(ValueKey('dm-conv-$_convPeer')),
          matching: find.text('4'),
        ),
        findsOneWidget,
      );
      await _drainTimers(tester);
      c.close();
    });
  });

  testWidgets('私信聊天页：对方新消息 WS 到达后自动追加，无需刷新', (tester) async {
    await _withRealHttp(() async {
      ApiClient.httpClient = http.Client();
      await _pump(tester, const DmChatPage(peerId: _peer, peerName: '端到端对方'));
      await _waitUntil(
        tester,
        () => find.text('我把歌单整理好了').evaluate().isNotEmpty,
      );
      expect(find.text('我把歌单整理好了'), findsOneWidget);

      await _connectBus(tester);
      final c = http.Client();
      await tester.runAsync(
        () => _sendDm(c, token: _tokPeer, content: '聊天页实时到达：我到了'),
      );
      await _waitUntil(
        tester,
        () => find.text('聊天页实时到达：我到了').evaluate().isNotEmpty,
      );
      expect(find.text('聊天页实时到达：我到了'), findsOneWidget);
      await _drainTimers(tester);
      c.close();
    });
  });

  testWidgets('互动通知二级列表：WS 新点赞自动插到顶部', (tester) async {
    await _withRealHttp(() async {
      ApiClient.httpClient = http.Client();
      await _pump(tester, const NotifListPage(kind: 'like'));
      await _waitUntil(tester, () => find.text('收到新点赞').evaluate().length == 2);
      expect(find.text('收到新点赞'), findsNWidgets(2));

      await _connectBus(tester);
      final c = http.Client();
      final post = await tester.runAsync(() async {
        final r = await c.post(
          Uri.parse('${ApiClient.baseUrl}/post'),
          headers: {
            'Authorization': 'Bearer $_tokMe',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'content': '实时点赞列表 E2E', 'boardId': ''}),
        );
        expect(r.statusCode, 200, reason: r.body);
        return jsonDecode(r.body) as Map<String, dynamic>;
      });
      final pid = ((post!['post'] as Map?)?['id'] ?? post['id']).toString();
      await tester.runAsync(() async {
        final r = await c.post(
          Uri.parse('${ApiClient.baseUrl}/post/$pid/like'),
          headers: {
            'Authorization': 'Bearer $_tokPeer',
            'Content-Type': 'application/json',
          },
          body: '{}',
        );
        expect(r.statusCode, 200, reason: r.body);
      });
      await _waitUntil(tester, () => find.text('收到新点赞').evaluate().length == 3);
      expect(find.text('收到新点赞'), findsNWidgets(3));
      await _drainTimers(tester);
      c.close();
    });
  });

  testWidgets('官方通知：管理端发布后聊天页 WS 自动追加富文本气泡并清角标', (tester) async {
    await _withRealHttp(() async {
      ApiClient.httpClient = http.Client();
      // 预热真实 HTTP 连接，页面 _load 仍独立拉取。
      await tester.runAsync(() => ApiClient.officialMessages());
      await _pump(tester, const OfficialMessagesPage());
      await _waitUntil(
        tester,
        () => find
            .byKey(const ValueKey('official-bubble-o2'))
            .evaluate()
            .isNotEmpty,
      );
      await _connectBus(tester);

      final c = http.Client();
      final rich = {
        'v': 1,
        'blocks': [
          {
            'type': 'heading',
            'level': 2,
            'spans': [
              {'text': '实时公告', 'bold': true, 'color': 'accent'},
            ],
          },
          {
            'type': 'paragraph',
            'spans': [
              {'text': '这条是 WebSocket 实时到达的富文本。'},
            ],
          },
        ],
      };
      final sent = await tester.runAsync(
        () => c.post(
          Uri.parse('${ApiClient.baseUrl}/admin/official'),
          headers: {
            'X-Community-Admin-Token': 'e2e-admin-token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'receiverUserId': _me,
            'content': '实时公告：WS 富文本',
            'rich': rich,
          }),
        ),
      );
      expect(sent!.statusCode, 200, reason: sent.body);

      // 页面不刷新、不重进，只等 WS；新富文本气泡应出现。
      await _waitUntil(
        tester,
        () => find.text('实时公告', findRichText: true).evaluate().isNotEmpty,
      );
      expect(find.text('实时公告', findRichText: true), findsOneWidget);
      expect(
        find.text('这条是 WebSocket 实时到达的富文本。', findRichText: true),
        findsOneWidget,
      );

      await _waitUntil(
        tester,
        () => NotifyBus.shared.currentOfficialUnread == 0,
      );
      expect(NotifyBus.shared.currentOfficialUnread, 0);

      await _settle(tester, ms: 800);
      await _drainTimers(tester);
      c.close();
    });
  });
}
