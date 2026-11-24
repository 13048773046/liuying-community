import 'dart:convert';

import 'package:community_app/api/client.dart';
import 'package:community_app/config.dart';
import 'package:community_app/pages/message/dm_chat_page.dart';
import 'package:community_app/widgets/image_box.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _ok(Map<String, dynamic> body) => http.Response(
  jsonEncode({'ok': true, ...body}),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('私信图片表情按普通图片气泡渲染，URL 不走 assets 路径', (tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    ApiClient.token = 'emoji-render-token';
    ApiClient.userId = 'me';
    ApiClient.httpClient = MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/dm/messages')) {
        return _ok({
          'list': [
            {
              'id': 'm1',
              'senderId': 'me',
              'content': 'emoji_official/liuying/ly01.webp',
              'msgType': 'image',
              'created': now - 5,
              'isRead': 1,
            },
          ],
          'peer': 'u1',
        });
      }
      if (path.endsWith('/dm/read')) return _ok({'read': true});
      if (path.endsWith('/dm/unread')) return _ok({'unread': 0});
      if (path.endsWith('/emojis')) return _ok({'list': []});
      if (path.endsWith('/emojis/favs')) return _ok({'list': []});
      return _ok({});
    });
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        // 直接构造气泡所需的背景色与主题，不登录、不访问网络。
        home: const DmChatPage(peerId: 'u1', peerName: '夏梓璇'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final bubble = tester.widget<BlurUpImage>(find.byType(BlurUpImage).first);
    expect(
      bubble.url,
      mediaUrl('emoji_official/liuying/ly01.webp'),
    );
    expect(bubble.url.contains('assets/emoji_text'), isFalse);
    expect(bubble.width, 180);
    expect(bubble.height, 180);
    // 表情必须走透明分支：不铺同色底、不做模糊垫底，按 contain 完整显示。
    expect(bubble.transparentBackground, isTrue);
    expect(bubble.fit, BoxFit.contain);
    expect(tester.takeException(), isNull);
  });

  tearDown(() {
    ApiClient.httpClient = http.Client();
    ApiClient.token = null;
    ApiClient.userId = null;
  });
}
