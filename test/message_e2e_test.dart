/// 消息已读端到端：真实 Python 后端 + 真实 SQLite + 真实 HTTP + 真实 WebSocket。
///
/// 不是 MockClient：每个用例启动独立临时库和 127.0.0.1 端口，从消息页点击
/// 「全部已读」、通知单条已读、私信进入/回执一路验证到数据库和界面。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'path_provider_mock.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/pages/message/dm_chat_page.dart';
import 'package:community_app/pages/message/message_page.dart';
import 'package:community_app/pages/message/notif_list_page.dart';
import 'package:community_app/services/notify_bus.dart';

const _me = 'e2e_me';
const _peer = 'e2e_peer';
const _tokMe = 'e2e-token-me';
const _tokPeer = 'e2e-token-peer';
final _root = Directory.current.path;

/// Flutter test binding 会把 HttpClient 换成 400 mock；这个 override 恢复真实实现。
class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

final _fixture = '$_root/community/tests/message_e2e_fixture.py';

Process? _server;
String? _dbPath;
int _portSeq = 8796;

Future<void> _loadFont(String name, String path) async {
  final f = File(path);
  if (!f.existsSync()) return;
  final bytes = await f.readAsBytes();
  final loader = FontLoader(name)
    ..addFont(Future.value(ByteData.view(bytes.buffer)));
  await loader.load();
}

Future<void> _loadFonts() async {
  await _loadFont('LAT', '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf');
  await _loadFont(
    'CJK',
    '/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf',
  );
  await _loadFont(
    'MaterialIcons',
    '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
}

ThemeData _theme() => ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  fontFamily: 'LAT',
  fontFamilyFallback: const ['CJK'],
  scaffoldBackgroundColor: const Color(0xFF000000),
);

Future<T> _withRealHttp<T>(Future<T> Function() body) {
  final overrides = _RealHttpOverrides();
  return HttpOverrides.runZoned(
    body,
    createHttpClient: (context) => overrides.createHttpClient(context),
  );
}

Future<void> _startServer() async {
  final port = _portSeq++;
  _dbPath = '/tmp/message_e2e_${DateTime.now().microsecondsSinceEpoch}.db';
  final p = await Process.start('python3', [
    _fixture,
    '--db',
    _dbPath!,
    '--port',
    '$port',
  ], workingDirectory: _root);
  _server = p;
  final ready = Completer<void>();
  final err = StringBuffer();
  p.stderr.transform(utf8.decoder).listen(err.write);
  p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((
    line,
  ) {
    if (line.startsWith('READY')) {
      if (!ready.isCompleted) ready.complete();
    } else if (line.startsWith('SERVER_FAILED') ||
        line.startsWith('SERVER_TIMEOUT')) {
      if (!ready.isCompleted) ready.completeError(StateError(line));
    }
  });
  p.exitCode.then((code) {
    if (!ready.isCompleted) {
      ready.completeError(StateError('fixture exited $code\n$err'));
    }
  });
  await ready.future.timeout(const Duration(seconds: 20));
  ApiClient.baseOverride = 'http://127.0.0.1:$port/community/api';
  ApiClient.token = _tokMe;
  ApiClient.userId = _me;
}

Future<void> _stopServer() async {
  NotifyBus.shared.disconnect();
  ApiClient.httpClient.close();
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
  if (_dbPath != null) {
    for (final suffix in ['', '-wal', '-shm']) {
      try {
        File(_dbPath! + suffix).deleteSync();
      } catch (_) {}
    }
    _dbPath = null;
  }
}

Future<void> _settleReal(WidgetTester tester, {int ms = 1500}) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(Duration(milliseconds: ms));
  });
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
    await _settleReal(tester, ms: 1200);
  }
}

Future<void> _waitForText(
  WidgetTester tester,
  String text, {
  int attempts = 10,
}) async {
  await _waitUntil(
    tester,
    () => find.text(text).evaluate().isNotEmpty,
    attempts: attempts,
  );
}

Future<void> _pumpReal(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(780, 1688);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(debugShowCheckedModeBanner: false, theme: _theme(), home: page),
  );
  await _settleReal(tester, ms: 1800);
}

void main() {
  mockPathProvider();
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(_loadFonts);

  setUp(() async {
    // Flutter test binding 默认把 HttpClient 换成 400 mock；E2E 必须恢复真实网络。
    HttpOverrides.global = _RealHttpOverrides();
    NotifyBus.enabled = false;
    NotifyBus.shared.clearUnread();
    NotifyBus.shared.clearDmUnread();
    NotifyBus.shared.clearOfficialUnread();
    await _startServer();
  });

  tearDown(() async {
    await _stopServer();
    NotifyBus.enabled = true;
  });

  test('真实后端：分类未读 / 分类已读 / 私信全部已读落到 SQLite', () async {
    await _withRealHttp(() async {
      ApiClient.httpClient = http.Client();
      final unread = await ApiClient.notificationsUnread();
      expect(unread['unread'], 4);
      expect(unread['officialUnread'], 2);
      expect(unread['byType'], {
        'like': 1,
        'comment': 1,
        'follow': 1,
        'audit': 1,
        'other': 0,
      });

      await ApiClient.markNotificationsRead(group: 'like');
      final afterLike = await ApiClient.notificationsUnread();
      expect(afterLike['unread'], 3);
      expect((afterLike['byType'] as Map)['like'], 0);
      expect((afterLike['byType'] as Map)['comment'], 1);

      await ApiClient.dmReadAll();
      final dm = await ApiClient.dmUnread();
      expect(dm['unread'], 0);
      final convs = await ApiClient.dmConversations();
      expect((convs['list'] as List).first['unread'], 0);
    });
  });

  testWidgets('消息页 → 全部已读：三类红点归零并落到后端', (tester) async {
    await _withRealHttp(() async {
      ApiClient.httpClient = http.Client();
      await _pumpReal(tester, const MessagePage());
      await _waitForText(tester, '9 条未读');
      expect(find.text('9 条未读'), findsOneWidget);
      expect(find.text('3 条未读私信'), findsOneWidget);
      expect(find.text('未读'), findsOneWidget);

      final allRead = find.ancestor(
        of: find.text('全部已读'),
        matching: find.byType(PressableScale),
      );
      expect(allRead, findsOneWidget);
      await tester.tap(allRead);
      await tester.pump();
      await _waitUntil(tester, () => find.text('9 条未读').evaluate().isEmpty);

      expect(find.text('9 条未读'), findsNothing);
      expect(find.text('3 条未读私信'), findsNothing);
      // 默认“私信”tab 下可见的是会话行的已读态；互动通知的已读态由下一条用例覆盖。
      expect(find.text('已读'), findsOneWidget);

      await tester.runAsync(() async {
        final unread = await ApiClient.notificationsUnread();
        expect(unread['unread'], 0);
        expect(unread['officialUnread'], 0);
        final dm = await ApiClient.dmUnread();
        expect(dm['unread'], 0);
      });
      // 等 CachedNetworkImage 的 10s 清理 timer 走完，避免测试结束仍挂 Timer。
      await tester.pump(const Duration(seconds: 11));
      await tester.pump();
    });
  });

  testWidgets('互动通知：进入不自动已读，单条点击落库并更新文案', (tester) async {
    await _withRealHttp(() async {
      ApiClient.httpClient = http.Client();
      await _pumpReal(tester, const NotifListPage(kind: 'like'));
      await _waitForText(tester, '未读');
      expect(find.text('未读'), findsOneWidget);
      expect(find.text('已读'), findsOneWidget);

      await tester.tap(find.textContaining('赞了你的帖子'));
      await tester.pump();
      await _waitUntil(tester, () => find.text('未读').evaluate().isEmpty);
      // 等 _refreshGlobalUnread 的 GET 真正落库并释放 timeout timer。
      await _settleReal(tester, ms: 1500);
      await _settleReal(tester, ms: 1000);
      expect(find.text('未读'), findsNothing);
      expect(find.text('已读'), findsNWidgets(2));

      await tester.runAsync(() async {
        final unread = await ApiClient.notificationsUnread();
        expect((unread['byType'] as Map)['like'], 0);
        expect(unread['unread'], 3);
      });
    });
  });

  testWidgets('私信聊天 → 真实 WS 已读回执让己方气泡实时变已读', (tester) async {
    NotifyBus.enabled = true;
    await _withRealHttp(() async {
      ApiClient.httpClient = http.Client();
      await _pumpReal(
        tester,
        const DmChatPage(peerId: _peer, peerName: '端到端对方'),
      );
      await _waitForText(tester, '未读');
      expect(find.text('未读'), findsOneWidget);
      expect(find.text('已读'), findsOneWidget);

      await tester.runAsync(() async {
        NotifyBus.shared.connect(_tokMe);
        await Future<void>.delayed(const Duration(milliseconds: 600));
      });
      await tester.pump();

      await tester.runAsync(() async {
        ApiClient.token = _tokPeer;
        await ApiClient.dmRead(_me);
        ApiClient.token = _tokMe;
        await Future<void>.delayed(const Duration(milliseconds: 700));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('未读'), findsNothing);
      expect(find.text('已读'), findsNWidgets(2));
      await tester.runAsync(() async {
        final dm = await ApiClient.dmUnread();
        expect(dm['unread'], 0);
      });
    });
  });
}
