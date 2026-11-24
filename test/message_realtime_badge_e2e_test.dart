/// 私信 / 互动 / 首页铃铛红点实时链路：
/// 真实 Python 后端 + 真实 SQLite + 真实 HTTP + 真实 WebSocket + 真实页面。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'path_provider_mock.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/pages/home/home_page.dart';
import 'package:community_app/pages/message/message_page.dart';
import 'package:community_app/services/notify_bus.dart';

Future<T> _withRealHttp<T>(Future<T> Function() body) {
  final overrides = _RealHttpOverrides();
  return HttpOverrides.runZoned(
    body,
    createHttpClient: (context) => overrides.createHttpClient(context),
  );
}

const _me = 'e2e_me';
const _peer = 'e2e_peer';
const _tokMe = 'e2e-token-me';
const _tokPeer = 'e2e-token-peer';
const _tokOther = 'e2e-token-other';
final _root = Directory.current.path;
final _fixture = '$_root/community/tests/message_e2e_fixture.py';

class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

Process? _server;
String? _dbPath;
int _portSeq = 8801;

Future<void> _startServer() async {
  final port = _portSeq++;
  _dbPath = '/tmp/message_realtime_${DateTime.now().microsecondsSinceEpoch}.db';
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

Future<void> _settle(WidgetTester tester, {int ms = 1200}) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() condition, {
  int attempts = 12,
}) async {
  for (var i = 0; i < attempts; i++) {
    if (condition()) return;
    await _settle(tester);
  }
}

http.Response _ok(Map<String, dynamic> body) => http.Response(
  jsonEncode({'ok': true, ...body}),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

http.Client _homeMock() => MockClient((req) async {
  final path = req.url.path;
  if (path.endsWith('/feed')) {
    return _ok({'list': <dynamic>[], 'hasMore': false, 'page': 1});
  }
  if (path.endsWith('/topics/hot')) return _ok({'list': <dynamic>[]});
  if (path.endsWith('/banners')) return _ok({'list': <dynamic>[]});
  if (path.endsWith('/apps/categories')) return _ok({'list': <dynamic>[]});
  if (path.endsWith('/apps')) {
    return _ok({'list': <dynamic>[], 'total': 0, 'page': 1, 'pageSize': 20});
  }
  return _ok({});
});

Future<Map<String, dynamic>> _postAsMe(http.Client c) async {
  final r = await c.post(
    Uri.parse('${ApiClient.baseUrl}/post'),
    headers: {
      'Authorization': 'Bearer $_tokMe',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({'content': '实时红点 E2E', 'boardId': ''}),
  );
  final j = jsonDecode(r.body) as Map<String, dynamic>;
  return (j['post'] as Map<String, dynamic>?) ?? j;
}

Future<void> _sendDmAsPeer(http.Client c) async {
  final r = await c.post(
    Uri.parse('${ApiClient.baseUrl}/dm/send'),
    headers: {
      'Authorization': 'Bearer $_tokPeer',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({'peer': _me, 'content': '实时私信红点'}),
  );
  expect(r.statusCode, 200, reason: r.body);
}

Future<void> _likeAsPeer(http.Client c, String postId) async {
  final r = await c.post(
    Uri.parse('${ApiClient.baseUrl}/post/$postId/like'),
    headers: {
      'Authorization': 'Bearer $_tokPeer',
      'Content-Type': 'application/json',
    },
    body: '{}',
  );
  expect(r.statusCode, 200, reason: r.body);
}

Future<void> _commentAsPeer(http.Client c, String postId) async {
  final r = await c.post(
    Uri.parse('${ApiClient.baseUrl}/post/$postId/comment'),
    headers: {
      'Authorization': 'Bearer $_tokPeer',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({'content': '实时评论红点'}),
  );
  expect(r.statusCode, 200, reason: r.body);
}

Future<void> _followAsOther(http.Client c) async {
  final r = await c.post(
    Uri.parse('${ApiClient.baseUrl}/user/e2e_me/follow'),
    headers: {
      'Authorization': 'Bearer $_tokOther',
      'Content-Type': 'application/json',
    },
    body: '{}',
  );
  expect(r.statusCode, 200, reason: r.body);
}

Future<void> _approveAsAdmin(http.Client c, String postId) async {
  final r = await c.post(
    Uri.parse('${ApiClient.baseUrl}/admin/posts/$postId/audit'),
    headers: {
      'X-Community-Admin-Token': 'e2e-admin-token',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({'action': 'approve'}),
  );
  expect(r.statusCode, 200, reason: r.body);
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

  testWidgets('消息页：WS 私信红点 3→4、互动红点 4→8，四类子角标同步', (tester) async {
    await _withRealHttp(() async {
      ApiClient.httpClient = http.Client();
      await _pump(tester, const MessagePage());
      await _waitUntil(
        tester,
        () => find.text('3 条未读私信').evaluate().isNotEmpty,
      );
      expect(find.text('3 条未读私信'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('feed-tab-badge-私信')),
          matching: find.text('3'),
        ),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        NotifyBus.shared.connect(_tokMe);
        await Future<void>.delayed(const Duration(milliseconds: 700));
      });

      final c = http.Client();
      await tester.runAsync(() => _sendDmAsPeer(c));
      expect(NotifyBus.shared.currentDmUnread, 4);
      await _waitUntil(
        tester,
        () => find.text('4 条未读私信').evaluate().isNotEmpty,
      );
      expect(find.text('4 条未读私信'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('feed-tab-badge-私信')),
          matching: find.text('4'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('互动'));
      await tester.pump();
      await _waitUntil(
        tester,
        () => find.text('4 条未读互动').evaluate().isNotEmpty,
      );
      expect(find.text('4 条未读互动'), findsOneWidget);
      for (final title in const ['赞与收藏', '评论', '新增粉丝', '审核通知']) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey('message-entry-badge-$title')),
            matching: find.text('1'),
          ),
          findsOneWidget,
          reason: '$title 初始角标应为 1',
        );
      }

      final post = await tester.runAsync(() => _postAsMe(c));
      await tester.runAsync(
        () => _likeAsPeer(c, (post!['id'] ?? '').toString()),
      );
      expect(NotifyBus.shared.currentUnread, 5);
      await _waitUntil(
        tester,
        () => find.text('5 条未读互动').evaluate().isNotEmpty,
      );
      expect(find.text('5 条未读互动'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('feed-tab-badge-互动')),
          matching: find.text('5'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('message-entry-badge-赞与收藏')),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );

      await tester.runAsync(
        () => _commentAsPeer(c, (post!['id'] ?? '').toString()),
      );
      expect(NotifyBus.shared.currentUnread, 6);
      await _waitUntil(
        tester,
        () => find.text('6 条未读互动').evaluate().isNotEmpty,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('message-entry-badge-评论')),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );

      await tester.runAsync(() => _followAsOther(c));
      expect(NotifyBus.shared.currentUnread, 7);
      await _waitUntil(
        tester,
        () => find.text('7 条未读互动').evaluate().isNotEmpty,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('message-entry-badge-新增粉丝')),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );

      await tester.runAsync(
        () => _approveAsAdmin(c, (post!['id'] ?? '').toString()),
      );
      expect(NotifyBus.shared.currentUnread, 8);
      await _waitUntil(
        tester,
        () => find.text('8 条未读互动').evaluate().isNotEmpty,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('message-entry-badge-审核通知')),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );
      c.close();
      NotifyBus.shared.disconnect();
      await tester.pump(const Duration(seconds: 16));
    });
  });

  testWidgets('首页铃铛：WS 新互动通知到达后红点出现', (tester) async {
    await _withRealHttp(() async {
      ApiClient.httpClient = _homeMock();
      await _pump(tester, const HomePage());
      await _waitUntil(
        tester,
        () =>
            find.byIcon(Icons.notifications_none_rounded).evaluate().isNotEmpty,
      );
      await tester.runAsync(() async {
        NotifyBus.shared.connect(_tokMe);
        await Future<void>.delayed(const Duration(milliseconds: 700));
      });
      await _settle(tester, ms: 600);
      // 先清掉夹具里的初始未读，验证「从无到有」而不是一直亮着。
      NotifyBus.shared.setUnread(0);
      await tester.pump();
      expect(find.byKey(const ValueKey('home-bell-dot')), findsNothing);

      final c = http.Client();
      final post = await tester.runAsync(() => _postAsMe(c));
      await tester.runAsync(
        () => _likeAsPeer(c, (post!['id'] ?? '').toString()),
      );
      expect(NotifyBus.shared.currentUnread, 5);
      await _waitUntil(
        tester,
        () => find.byKey(const ValueKey('home-bell-dot')).evaluate().isNotEmpty,
      );
      expect(find.byKey(const ValueKey('home-bell-dot')), findsOneWidget);
      expect(NotifyBus.shared.currentUnread, 5);
      c.close();
    });
  });
}
