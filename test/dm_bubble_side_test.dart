import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/pages/message/dm_chat_page.dart';

http.Response _ok(Map<String, dynamic> body) => http.Response(
  jsonEncode({'ok': true, ...body}),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  testWidgets('冷启动 userId 未回填时，自己的私信仍在右侧', (tester) async {
    ApiClient.token = 'dm-side-token';
    ApiClient.userId = null;
    ApiClient.meProfile = null;
    ApiClient.httpClient = MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/dm/messages')) {
        return _ok({
          'list': [
            {
              'id': 'm1',
              'senderId': 'u1',
              'content': '对方发的',
              'msgType': 'text',
              'created': 1763550000,
              'isRead': 1,
            },
            {
              'id': 'm2',
              'senderId': 'me',
              'content': '我自己发的',
              'msgType': 'text',
              'created': 1763550001,
              'isRead': 0,
            },
          ],
          'peer': 'u1',
        });
      }
      if (path.endsWith('/dm/read')) return _ok({'read': true});
      if (path.endsWith('/dm/send')) {
        return _ok({'id': 'sent-1', 'created': 1763550002});
      }
      if (path.endsWith('/dm/unread')) return _ok({'unread': 0});
      if (path.endsWith('/emojis')) return _ok({'list': <dynamic>[]});
      if (path.endsWith('/emojis/favs')) return _ok({'list': <dynamic>[]});
      return _ok({});
    });
    addTearDown(() {
      ApiClient.httpClient = http.Client();
      ApiClient.userId = null;
      ApiClient.meProfile = null;
      ApiClient.token = null;
    });

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: DmChatPage(peerId: 'u1', peerName: '夏梓璇'),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(
      find.byKey(const ValueKey('dm_bubble_m1_in')),
      findsOneWidget,
      reason: '对方消息应在左侧',
    );
    expect(
      find.byKey(const ValueKey('dm_bubble_m2_out')),
      findsOneWidget,
      reason: '自己的消息必须在右侧，不能变成对方气泡',
    );
    // 冷启动发送：乐观气泡也必须按“自己”渲染，不能借用对方头像跑到左边。
    await tester.enterText(find.byType(TextField), '冷启动刚发的');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(
      find.byKey(const ValueKey('dm_bubble_sent-1_out')),
      findsOneWidget,
      reason: '发送成功后自己的气泡仍在右侧',
    );
    expect(tester.takeException(), isNull);
  });
}
