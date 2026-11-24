/// 消息体系视觉验收图：私信列表（面包屑/大角标/已读态）、互动通知已读态、
/// 私信气泡未读/已读回执。仅用于人工检查，不替代交互回归。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'path_provider_mock.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/pages/message/dm_chat_page.dart';
import 'package:community_app/pages/message/message_page.dart';
import 'package:community_app/pages/message/notif_list_page.dart';
import 'package:community_app/services/notify_bus.dart';

http.Response _ok(Map<String, dynamic> body) => http.Response(
  jsonEncode({'ok': true, ...body}),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

final _now = DateTime.now().millisecondsSinceEpoch / 1000;

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

void _mockApi() {
  ApiClient.token = 'shot-token';
  ApiClient.userId = 'me';
  ApiClient.httpClient = MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/notifications/unread')) {
      return _ok({
        'unread': 5,
        'officialUnread': 2,
        'byType': {'like': 2, 'comment': 1, 'follow': 1, 'audit': 1},
      });
    }
    if (path.endsWith('/notifications') && request.method == 'GET') {
      return _ok({
        'list': [
          {
            'id': 'n1',
            'type': 'community_like',
            'title': '收到新点赞',
            'content': '赞了你的帖子',
            'fromUserName': '夏梓璇',
            'isRead': 0,
            'created': _now - 60,
          },
          {
            'id': 'n2',
            'type': 'community_like',
            'title': '收到新点赞',
            'content': '赞了你的另一条帖子',
            'fromUserName': '阿澈',
            'isRead': 1,
            'created': _now - 240,
          },
        ],
        'hasMore': false,
      });
    }
    if (path.endsWith('/dm/conversations')) {
      return _ok({
        'list': [
          {
            'id': 'c1',
            'peer': {'id': 'u1', 'name': '夏梓璇', 'avatar': ''},
            'lastMsg': '晚上一起听歌吗',
            'lastType': 'text',
            'lastTime': _now - 30,
            'unread': 3,
          },
          {
            'id': 'c2',
            'peer': {'id': 'u2', 'name': '林小满', 'avatar': ''},
            'lastMsg': '下次再聊',
            'lastType': 'text',
            'lastTime': _now - 300,
            'unread': 0,
          },
        ],
        'hasMore': false,
      });
    }
    if (path.endsWith('/dm/unread')) return _ok({'unread': 3});
    if (path.endsWith('/dm/read')) return _ok({'read': true});
    if (path.endsWith('/dm/messages')) {
      return _ok({
        'list': [
          {
            'id': 'm1',
            'senderId': 'me',
            'content': '今晚一起听新歌吗？',
            'msgType': 'text',
            'created': _now - 50,
            'isRead': 1,
          },
          {
            'id': 'm2',
            'senderId': 'me',
            'content': '我把歌单整理好了',
            'msgType': 'text',
            'created': _now - 20,
            'isRead': 0,
          },
          {
            'id': 'm3',
            'senderId': 'u1',
            'content': '好啊，晚点一起听',
            'msgType': 'text',
            'created': _now,
            'isRead': 0,
          },
        ],
      });
    }
    if (path.endsWith('/official-messages/read')) return _ok({'read': true});
    if (path.endsWith('/official-messages')) return _ok({'list': []});
    return _ok({});
  });
}

Future<GlobalKey> _pumpPage(
  WidgetTester tester,
  Widget page, {
  required Size size,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        home: ColoredBox(color: const Color(0xFF000000), child: page),
      ),
    ),
  );
  await tester.pump();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
  return key;
}

void main() {
  mockPathProvider();
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(_loadFonts);

  setUp(() {
    NotifyBus.enabled = false;
    NotifyBus.shared.clearUnread();
    NotifyBus.shared.clearDmUnread();
    NotifyBus.shared.clearOfficialUnread();
  });

  tearDown(() {
    ApiClient.httpClient = http.Client();
    ApiClient.token = null;
    ApiClient.userId = null;
  });

  testWidgets('私信列表 390：大角标 + 未读/已读', (tester) async {
    _mockApi();
    final key = await _pumpPage(
      tester,
      const MessagePage(),
      size: const Size(390, 844),
    );
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/message_private_390.png'),
    );
  });

  testWidgets('私信列表 320：窄屏不挤爆', (tester) async {
    _mockApi();
    final key = await _pumpPage(
      tester,
      const MessagePage(),
      size: const Size(320, 700),
    );
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/message_private_320.png'),
    );
  });

  testWidgets('互动通知 390：未读/已读 + 全部已读', (tester) async {
    _mockApi();
    final key = await _pumpPage(
      tester,
      const NotifListPage(kind: 'like'),
      size: const Size(390, 844),
    );
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/message_notif_390.png'),
    );
  });

  testWidgets('私信聊天 390：未读/已读回执', (tester) async {
    _mockApi();
    final key = await _pumpPage(
      tester,
      const DmChatPage(peerId: 'u1', peerName: '夏梓璇'),
      size: const Size(390, 844),
    );
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/message_chat_390.png'),
    );
  });
}
