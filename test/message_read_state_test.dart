/// 消息已读态回归：大角标、会话/通知已读文案、私信气泡已读回执、
/// 「进入通知列表不再自动全部已读」和一键已读覆盖三类消息。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/pages/message/dm_chat_page.dart';
import 'package:community_app/pages/message/dm_conversations_page.dart';
import 'package:community_app/pages/message/message_page.dart';
import 'package:community_app/pages/message/notif_list_page.dart';
import 'package:community_app/services/notify_bus.dart';

http.Response _ok(Map<String, dynamic> body) => http.Response(
      jsonEncode({'ok': true, ...body}),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

final _now = DateTime.now().millisecondsSinceEpoch / 1000;

List<Map<String, dynamic>> _notifications() => [
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
        'type': 'community_comment',
        'title': '收到新评论',
        'content': '这条内容真好看',
        'fromUserName': '林小满',
        'isRead': 1,
        'created': _now - 120,
      },
      {
        'id': 'n3',
        'type': 'community_interact',
        'title': '新关注',
        'content': '关注了你',
        'fromUserName': '阿澈',
        'isRead': 0,
        'created': _now - 180,
      },
      {
        'id': 'n4',
        'type': 'community_like',
        'title': '收到新点赞',
        'content': '赞了你的另一条帖子',
        'fromUserName': '阿澈',
        'isRead': 1,
        'created': _now - 240,
      },
    ];

List<Map<String, dynamic>> _conversations() => [
      {
        'id': 'c1',
        'peer': {'id': 'u1', 'name': '夏梓璇', 'avatar': ''},
        'lastMsg': '晚上一起听歌吗',
        'lastType': 'text',
        'lastTime': _now - 30,
        'unread': 2,
      },
      {
        'id': 'c2',
        'peer': {'id': 'u2', 'name': '林小满', 'avatar': ''},
        'lastMsg': '下次再聊',
        'lastType': 'text',
        'lastTime': _now - 300,
        'unread': 0,
      },
    ];

void _mockApi({
  required List<String> notifReads,
  required List<String> dmReads,
}) {
  ApiClient.token = 'test-token';
  ApiClient.userId = 'me';
  ApiClient.httpClient = MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/notifications/unread')) {
      return _ok({
        'unread': 3,
        'officialUnread': 2,
        'byType': {'like': 1, 'comment': 0, 'follow': 1, 'audit': 0},
      });
    }
    if (path.endsWith('/notifications') && request.method == 'GET') {
      return _ok({'list': _notifications(), 'hasMore': false});
    }
    if (path.endsWith('/notifications/read') && request.method == 'POST') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      notifReads.add(jsonEncode(body));
      return _ok({'read': true});
    }
    if (path.endsWith('/dm/conversations')) {
      return _ok({'list': _conversations(), 'hasMore': false});
    }
    if (path.endsWith('/dm/unread')) return _ok({'unread': 2});
    if (path.endsWith('/dm/read-all') && request.method == 'POST') {
      dmReads.add('__all__');
      return _ok({'read': true});
    }
    if (path.endsWith('/dm/read') && request.method == 'POST') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      dmReads.add((body['peer'] ?? '').toString());
      return _ok({'read': true});
    }
    if (path.endsWith('/dm/messages')) {
      return _ok({
        'list': [
          {
            'id': 'm1',
            'senderId': 'me',
            'content': '你好',
            'msgType': 'text',
            'created': _now - 20,
            'isRead': 0,
          },
          {
            'id': 'm2',
            'senderId': 'me',
            'content': '在吗',
            'msgType': 'text',
            'created': _now - 10,
            'isRead': 1,
          },
          {
            'id': 'm3',
            'senderId': 'u1',
            'content': '在的',
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

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  testWidgets('大号角标：20 宽、11 号字、20 高', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Center(child: CountBadge(count: 9, large: true)),
    ));
    await _settle(tester);
    final box = tester.widget<Container>(
      find.descendant(
        of: find.byType(CountBadge),
        matching: find.byType(Container),
      ).first,
    );
    expect(box.constraints?.minWidth, 20);
    expect(box.constraints?.minHeight, 20);
    final text = tester.widget<Text>(find.text('9'));
    expect(text.style?.fontSize, 11);
  });

  testWidgets('会话列表：未读加粗 + 未读/已读状态 + 大数字角标', (tester) async {
    final rows = [
      buildConvTile(_conversations()[0], onTap: () {}),
      buildConvTile(_conversations()[1], onTap: () {}),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFF000000),
        body: ListView(children: rows),
      ),
    ));
    await _settle(tester);
    expect(find.text('未读'), findsOneWidget);
    expect(find.text('已读'), findsOneWidget);
    expect(find.byType(CountBadge), findsOneWidget);
    final badge = tester.widget<CountBadge>(find.byType(CountBadge));
    expect(badge.large, isTrue);
    expect(badge.count, 2);
  });

  testWidgets('互动通知：未读/已读文案，未读行可点成已读', (tester) async {
    final reads = <String>[];
    _mockApi(notifReads: reads, dmReads: []);
    await tester.pumpWidget(const MaterialApp(
      home: NotifListPage(kind: 'like'),
    ));
    await _settle(tester);
    expect(reads, isEmpty, reason: '进入列表不得自动标已读');
    expect(find.text('未读'), findsOneWidget);
    expect(find.text('已读'), findsOneWidget);

    await tester.tap(find.text('收到新点赞').first);
    await _settle(tester);
    expect(reads.length, 1);
    expect(jsonDecode(reads.single)['id'], 'n1');
    expect(find.text('未读'), findsNothing);
    expect(find.text('已读'), findsNWidgets(2));
  });

  testWidgets('消息页：总未读含官方与私信，一键已读覆盖三类', (tester) async {
    final notifReads = <String>[];
    final dmReads = <String>[];
    _mockApi(notifReads: notifReads, dmReads: dmReads);
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: MessagePage()));
    await _settle(tester);
    expect(find.text('7 条未读'), findsOneWidget);
    expect(find.text('夏梓璇'), findsOneWidget);
    expect(notifReads, isEmpty);

    await tester.tap(find.text('全部已读'));
    await _settle(tester);
    expect(notifReads.length, 1);
    expect(dmReads, ['__all__']);
    expect(find.text('7 条未读'), findsNothing);
    expect(find.text('已读'), findsNWidgets(2));
  });

  testWidgets('私信聊天：己方未读/已读可见，收到回执后变已读', (tester) async {
    _mockApi(notifReads: [], dmReads: []);
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(
      home: DmChatPage(peerId: 'u1', peerName: '夏梓璇'),
    ));
    await _settle(tester);
    expect(find.text('未读'), findsOneWidget);
    expect(find.text('已读'), findsOneWidget);

    NotifyBus.shared.onDmRead.add({
      'kind': 'dm_read',
      'convId': 'c1',
      'peer': 'u1',
      'readAt': _now,
    });
    await _settle(tester);
    expect(find.text('未读'), findsNothing);
    expect(find.text('已读'), findsNWidgets(2));
  });
}
